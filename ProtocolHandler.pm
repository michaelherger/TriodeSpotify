package Plugins::Spotify::ProtocolHandler;

use strict;

use Scalar::Util qw(blessed);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use vars qw(@ISA);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Spotify::Image;

my $prefs = preferences('plugin.spotify');
my $sprefs= preferences('server');
my $log;

use constant MAX_TRACK_REQUEST => 5; # max outstanding track requests before queuing

my %fetching; # hash of track urls we are fetching, to avoid multiple fetches
my @fetchQ;   # Q of tracks to fetch
my $fetchInProgress = 0;

my $otherHandler;

BEGIN {
	$log = logger('plugin.spotify');

	$otherHandler = Slim::Player::ProtocolHandlers->handlerForProtocol('spotify');

	$log->info("Working with existing handler: $otherHandler");

	push @ISA, ($otherHandler || 'Slim::Formats::RemoteStream');
	
	Slim::Player::ProtocolHandlers->registerHandler(spotify  => __PACKAGE__);
	Slim::Player::ProtocolHandlers->registerHandler(spotifyd => 'Plugins::Spotify::ProtocolHandlerSpotifyd');
}

sub _useOtherStreaming {
	my ($class, $client) = @_;

	if ($otherHandler && $client->can('spDirectHandlers') && $client->spDirectHandlers =~ /spotify/ &&
	   !$client->isSynced(1) && !$prefs->get('nootherstreaming')) {

		return 1;
	}
	
	return 0;
}

sub new {
	my ($class, $args) = @_;

	my $client = $args->{'client'};

	if ($args->{'url'} =~ /spotify:artist|spotify:album|spotify:user:.*:playlist/) {
		return undef;
	}

	$log->warn("Spotify client not supported: " . $client->model);

	$client->showBriefly({ line => [ string('PLUGIN_SPOTIFY'), string('PLUGIN_SPOTIFY_PLAYER_NOT_SUPPORTED') ] }, 
						 { block => 1, duration => 5 });

	return undef;
}

sub otherHandler { $otherHandler }

sub isPlaylistURL { 0 }

sub isRemote { 1 }

sub canSeek { 1 }

sub bufferThreshold { 80 }

sub formatOverride {
	my ($class, $song) = @_;

	return if !defined $song;

	my $client = $song->master;

	if ($class->_useOtherStreaming($client)) {
		return $class->SUPER::formatOverride($song);
	}

	# if transcoding is disabled always stream as pcm
	if (!main::TRANSCODING) {
		return 'pcm';
	}

	# if a local Squeezelite player and pcm enabled then send raw pcm
	if ($client->can('myFormats') && $client->myFormats->[-1] eq 'loc') {
		if (grep(/pcm/, @{$client->myFormats})) {
			return 'pcm';
		}
	}

	# this allows file types to be used to select format between pcm and flac streaming
	return 'sflc';
}

sub getMetadataFor {
	# don't use $_[3] as it is forceCurrent used by AudioScrobbler
	my ($class, $client, $url, undef, $fetch) = @_; 

	# divert to other handler
	if ($otherHandler && $prefs->get('othermeta')) {
		return $class->SUPER::getMetadataFor($client, $url);
	} 

	$url =~ s{^spotify://}{spotify:};

	my $track = Slim::Schema::RemoteTrack->fetch($url);

	my $key = $url . ($fetch || '');

	if ($track && $track->stash->{'albumuri'} && !$fetch) {

		my $image = Plugins::Spotify::Image->uri($track->cover);

		my $starred = $track->stash->{'starred'};

		my $ret = {
			title    => $track->title,
			artist   => $track->artistname,
			album    => $track->albumname,
			duration => $track->secs,
			icon     => $image,
			cover    => $image,
			bitrate  => $prefs->get('bitrate') . 'k VBR',
			type     => 'Ogg Vorbis (Spotify)',
			starred  => $starred,
			albumuri => $track->stash->{'albumuri'},
			artistA  => $track->stash->{'artists'},
		};

		# if playing a radio stream then override shuffle buttons for starred icon
		if ($client && Plugins::Spotify::Radio::playingRadioStream($client)) {
			$ret->{'buttons'} = {
				shuffle  => {
					jiveStyle => $starred ? 'thumbsUp' : 'thumbsUpDisabled',
					command   => [ 'spotify', 'star', $track->url, $starred ? 0 : 1 ],
				},
			};
		}

		return $ret;

	} elsif (!$fetching{$key} && $url =~ /^spotify:track/) {

		$log->info("queuing fetch of meta for $url");

		push @fetchQ, { url => $url, client => $client, fetch => $fetch };

		$fetching{$key} = 1;

		if ($fetchInProgress < MAX_TRACK_REQUEST) {
			_fetch();
		}
	}

	return {};
}

sub _fetch {
	my $entry  = shift @fetchQ || return;
	my $url    = $entry->{'url'};
	my $client = $entry->{'client'};
	my $fetch  = $entry->{'fetch'};

	$log->info("fetching meta for $url fetch: $fetch");

	my $key = $url . ($fetch || '');

	Slim::Networking::SimpleAsyncHTTP->new(
		
		sub {
			my $track = eval { from_json($_[0]->content) };
			
			if ($@) {
				$log->warn($@);
			}

			my $obj;

			if ($track->{'uri'} && $track->{'uri'} eq $url) {
			
				$log->info("caching meta for $url");

				my @artists;
				for my $artist (@{$track->{'artists'}}) {
					push @artists, $artist->{'name'};
				}
				
				my $secs = $track->{'duration'} / 1000;
				
				$obj = Slim::Schema::RemoteTrack->updateOrCreate($url, {
					title   => $track->{'name'},
					artist  => join(", ", @artists),
					album   => $track->{'album'},
					secs    => $secs,
					cover   => $track->{'cover'},
					tracknum=> $track->{'index'},
				});
				
				$obj->stash->{'starred'} = $track->{'starred'};
				$obj->stash->{'albumuri'} = $track->{'albumuri'};
				$obj->stash->{'artists'} = $track->{'artists'};

				if ($track->{'largecover'}) {
					$log->info("adding large cover: " . $track->{'cover'} . " -> " . $track->{'largecover'});
					$Plugins::Spotify::Image::largeImageMap{ $track->{'cover'} } = $track->{'largecover'};
				}

				if (blessed($fetch)) {
					
					$log->info("updating temporary duration for url: $url to $secs");
					
					$fetch->duration($secs);
				}
			}

			delete $fetching{$key};
			
			# Update the playlist when last response received to update web playlist
			# Only do so if we actually got metadata to avoid continually fetching bad track metadata
			if (keys %fetching == 0 && $obj) {
				$client->currentPlaylistUpdateTime(Time::HiRes::time());
				Slim::Control::Request::notifyFromArray($client, [ 'newmetadata' ]);
			}

			$fetchInProgress--;
			_fetch();
		}, 
		
		sub {
			$log->warn("error fetching track data: $_[1]");

			Plugins::Spotify::Spotifyd->countError;

			delete $fetching{$key};
			$fetchInProgress--;
			_fetch();
		},
		
		{ timeout => 35 },
		
	)->get(Plugins::Spotify::Spotifyd->uri("$url/browse.json"));

	$fetchInProgress++;
}

sub trackInfoURL {
	my ( $class, $client, $url ) = @_;

	# divert to other handler
	if ($otherHandler && $prefs->get('othermeta')) {
		return $class->SUPER::trackInfoURL($client, $url);
	}

	return undef;
}

sub canDirectStream {
	my ($class, $client, $url) = @_;

	# divert to other streaming if appropriate
	if ($class->_useOtherStreaming($client)) {
		$log->info("Playing via $otherHandler: $url");
		return $class->SUPER::canDirectStream($client, $url);
	}
	
	if (!$client->isPlayer || $url !~ /:track:|:\/\/track:/) {
		# falls through to class->new
		return undef;
	}
	
	$log->info("Playing via spotifyd: $url");

	my $song = $client->streamingSong;

	# ensure a duration is stored in the song object to enable StreamingController to know when a track has completed
	# as long as the LRU size is large enough we should never get here, but protect against having no duration
	# as StreamingControler uses this as a trigger to repeat the current track at end rather than move on to the next
	if (!$song->duration) {

		$log->info("no duration for url: $url - setting temporary duration");

		$song->duration(-1);

		$class->getMetadataFor($client, $url, undef, $song);

	} else {

		# trigger metadata fetch if it is not in remoteTrack cache
		$class->getMetadataFor($client, $url);
	}

	my $host = Slim::Utils::Network::serverAddr();
	my $port = $prefs->get('httpport');

	# for clients connecting on localhost always use localhost address to connect to helper
	if ($client->ip eq '127.0.0.1') {
		$host = '127.0.0.1';
	}

	$url =~ s{^spotify://}{spotify:};
	
	return "spotifyd://$host:$port/$url";
}

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;

	if ($class->_useOtherStreaming($client)) {
		return $class->SUPER::getSeekData($client, $song, $newtime);
	}

	return { timeOffset => $newtime };
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	if ($song->track->url =~ /spotify:artist|spotify:album|spotify:user:.*:playlist/) {
		my $uri = $song->track->url;

		$log->info("exploding $uri into tracks");

		# FIXME?? - this loads the playlist with the new tracks replacing all existing tracks
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time(), sub {
			$song->master->execute([ 'spotifyplcmd', 'cmd:load', "uri:$uri" ]);
		});
	}

	if ($class->_useOtherStreaming($song->master)) {
		return $class->SUPER::getNextTrack($song, $successCb, $errorCb);
	}

	$successCb->();
}

sub onStream {
	my ($class, $client, $song) = @_;

	if ($class->_useOtherStreaming($client)) {
		return $class->SUPER::onStream($client, $song);
	}
}

sub handleDirectError {
	my ($class, $client, $url, $response, $status_line) = @_;

	if ($class->_useOtherStreaming($client)) {
		$client->failedDirectStream($status_line);
		return;
	}

	if ($response == 999 && $status_line =~ /999 Bad Player (.*)/) {
		$log->warn("stream failed - bad player: $1");
		$client->controller()->playerStreamingFailed($client, sprintf(string("PLUGIN_SPOTIFY_BAD_PLAYER"), $1));
		return;
	}

	if ($response == 403) {

		$log->info("track unavailable");

		# indicate track has started and then failed to force move to next track
		$client->controller()->playerTrackStarted($client);
		$client->controller()->playerStreamingFailed($client, "PLUGIN_SPOTIFY_STREAM_FAILED1");

	} elsif ($response == 503) {

		$client->controller()->playerStreamingFailed($client, "PLUGIN_SPOTIFY_STREAM_FAILED2");

		$log->warn("failed to play stream ($status_line) - restarting helper");
		
		$log->warn("Please check your firewall to ensure spotifyd.exe/spotifyd is able to accept incomming connections");
		
		# note this blocks the server, try to get the error message out first...
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1.0, sub { Plugins::Spotify::Spotifyd->restartD });
	}
}

sub suppressPlayersMessage {
	my ($class, $client, $song, $string) = @_;

	if ($class->_useOtherStreaming($client)) {
		return $class->SUPER::suppressPlayersMessage($client, $song, $string);
	}

	if ($string eq 'REBUFFERING') {

		$song->pluginData()->{'rebuffer'} ||= 0;

		if ($song->pluginData()->{'rebuffer'}++ > 15 && Time::HiRes::time() - Plugins::Spotify::Spotifyd->reloginTime > 15) {

			$log->info("buffer threshold exceeded");

			Plugins::Spotify::Spotifyd->relogin;

			$song->pluginData()->{'rebuffer'} = 0;
		}
	}
	
	return undef;
}	

1;
