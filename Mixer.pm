package Plugins::SpotifyProtocolHandler::Mixer;

use strict;
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant MIN_TRACKS_LEFT => 2;		# minimum number of tracks left before we add our own

my $prefs = preferences('plugin.spotify');
my $serverprefs = preferences('server');
my $log = logger('plugin.spotifyprotocolhandler');

sub init {
	# listen to playlist change events so we know when our own playlist ends
	Slim::Control::Request::subscribe(\&onPlaylistChange, [['playlist'], ['cant_open', 'newsong', 'delete', 'resume']]);
}

sub onPlaylistChange {
	my $request = shift;
	my $client  = $request->client();

	return if !defined $client;
	$client = $client->master;
	return if $request->source && $request->source eq __PACKAGE__;
	return if !$prefs->client($client)->get('neverStopTheMusic');

	Slim::Utils::Timers::killTimers($client, \&neverStopTheMusic);

	# Spotify sometimes fails to load tracks and is skipping them without us getting the 'newsong' event
	if ( $request->isCommand( [['playlist'], ['cant_open']] ) ) {
		# return unless this is a "103: not available in your country" Spotify error
		return if $request->getParam('_url') !~ /^spotify/ || $request->getParam('_error') !~ /^103/;

		$client->pluginData('forceResume') || $client->pluginData( forceResume => Slim::Player::Source::playmode($client) eq 'play' ? 1 : 0 );
	}

	# don't interfere with the automatically adding RandomPlay and SugarCube plugins
	# stop smart mixing when a new RandomPlay mode is started or SugarCube is at work
	if (
		( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::RandomPlay::Plugin') && Slim::Plugin::RandomPlay::Plugin::active($client) )
		|| ( Slim::Utils::PluginManager->isEnabled('Plugins::SugarCube::Plugin') && preferences('plugin.SugarCube')->client($client)->get('sugarcube_status') )
	) {
		return;
	}

	my $songIndex = Slim::Player::Source::streamingSongIndex($client) || 0;
	
	if ( main::INFOLOG && $log->is_info ) {
		$log->info(sprintf("Received command %s", $request->getRequestString));
		$log->info(sprintf("While in mode: %s, from %s", ($prefs->client($client)->get('session_id') || 'new!'), $client->name));
	}

	if ( $request->isCommand( [['playlist'], ['newsong', 'delete', 'cant_open']] ) ) {
		# create mix based on last track if we near the end, repeat is off and neverStopTheMusic is set
		if ( !Slim::Player::Playlist::repeat($client) ) {
			# Delay start of the mix if we're called while we're playing one single track only.
			# We might be in the middle of adding new tracks.
			if ($songIndex == 0) {
				my $delay = (Slim::Player::Source::playingSongDuration($client) - Slim::Player::Source::songTime($client)) / 2;
				$delay = 0 if $delay < 0;
				Slim::Utils::Timers::setTimer($client, time + $delay, \&neverStopTheMusic);
			}
			else {
				neverStopTheMusic($client);
			}
		}
	} 
}

sub neverStopTheMusic {
	my ($client) = @_;
	
	my $songIndex = Slim::Player::Source::streamingSongIndex($client) || 0;
	my $songsRemaining = Slim::Player::Playlist::count($client) - $songIndex - 1;

	main::INFOLOG && $log->info("$songsRemaining songs remaining, songIndex = $songIndex");

	my $numTracks = $prefs->get('newtracks') || MIN_TRACKS_LEFT;
	
	if ($songsRemaining < $numTracks) {
		# grab five random tracks to seed the mix (if available)
		my ($trackId, $artist, $title, $duration, $tracks);
		
		foreach (@{ Slim::Player::Playlist::playList($client) }) {
			($artist, $title, $duration, $trackId) = getMixablePropertiesFromTrack($client, $_);
			
			next unless defined $artist && defined $title;
	
			push @$tracks, {
				id => $trackId,
				artist => $artist,
				title => $title
			};
		}

		# pick five random tracks from the playlist
		if (scalar @$tracks > 5) {
			Slim::Player::Playlist::fischer_yates_shuffle($tracks);
			splice(@$tracks, 5);
		}
		
		# don't seed from radio stations - only do if we're playing from some track based source
		if ($tracks && @$tracks && $duration) {
			main::INFOLOG && $log->info("Auto-mixing from random tracks in current playlist");
			
			my $http = Slim::Networking::SqueezeNetwork->new(
				sub {
					my $http = shift;
					my $client = $http->params->{client} || return;
					
					my $content = eval { from_json( $http->content ) };
					
					if ( $@ || ($content && $content->{error}) ) {
						$http->error( $@ || $content->{error} );
					}
					elsif ( $content && ref $content && $content->{body} && (my $items = $content->{body}->{outline}) ) {
						my @tracks = grep { $_ } map { $_->{play} } @$items;
						
						if ( Slim::Player::Playlist::count($client) + scalar(@tracks) > preferences('server')->get('maxPlaylistLength') ) {
							# Delete tracks before this one on the playlist
							for (my $i = 0; $i < scalar(@tracks); $i++) {
								my $request = $client->execute(['playlist', 'delete', 0]);
								$request->source(__PACKAGE__);
							}
						}
						
						my $request = $client->execute(['playlist', 'addtracks', 'listRef', \@tracks ]);
						$request->source(__PACKAGE__);
					}
				},
				sub {
					my $http = shift;

					if ( main::DEBUGLOG && $log->is_debug ) {
						$log->debug( 'getMix failed: ' . $http->error );
					}
				},
				{
					client => $client,
					timeout => 15,
				},
			);

			my $json = eval { to_json({
				seed => $tracks
			}) };
			
			if ( $@ ) {
				$log->error("JSON encoding failes: $@");
				$json = '';
			}

			$http->post( $http->url( '/api/spotify/v1/opml/autoDJ' ), $json );
		}
		elsif (main::INFOLOG && $log->is_info) {
			$log->info("No mixable items found in current playlist!");
		}
	}
}

sub getMixablePropertiesFromTrack {
	my ($client, $track) = @_;
	
	return unless blessed $track;

	my $id     = $track->url;
	my $artist = $track->artistName;
	my $title  = $track->title;
	my $duration = $track->duration;
				
	# we might have to look up titles for remote sources
	if ( !($artist && $title && $duration) && $track && $track->remote && $id ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($id);
		if ( $handler && $handler->can('getMetadataFor') ) {
			my $remoteMeta = $handler->getMetadataFor( $client, $id );
			$artist   ||= $remoteMeta->{artist};
			$title    ||= $remoteMeta->{title};
			$duration ||= $remoteMeta->{duration};
		}
	}
	
	return ($artist, $title, $duration, $id =~ /^spotify:/ ? $id : '' );
}

1;