package Plugins::Spotify::Plugin;

# Plugin to play spotify streams using helper app & libspotify
#
# (c) Adrian Smith (Triode), 2010, 2011 - see license.txt for details
#
# The plugin relies on a separate binary spotifyd which is linked to libspotify

use strict;
use base 'Slim::Plugin::OPMLBased';

use JSON::XS::VersionOneAndTwo;
use File::Spec::Functions;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Slim::Utils::Strings qw(string cstring);

use Plugins::Spotify::Settings;
use Plugins::Spotify::Spotifyd;
use Plugins::Spotify::Image;
use Plugins::Spotify::Radio;
use Plugins::Spotify::Library;
use Plugins::Spotify::Recent;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.spotify',
	'defaultLevel' => 'WARN',
	'description'  => string('PLUGIN_SPOTIFY'),
}); 

my $prefs  = preferences('plugin.spotify');
my $sprefs = preferences('server');

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		tag    => 'spotify',
		feed   => \&toplevel,
		is_app => $class->can('nonSNApps') && $prefs->get('is_app') ? 1 : undef,
		menu   => 'radios',
		weight => 2,
	);

	# hack for Synology archnames meaning binary dirs don't get put on findBin path
	my $arch = Slim::Utils::OSDetect->details->{'binArch'};
	if ($arch =~ /^MARVELL/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'arm-linux' ));
	}
	if ($arch =~ /X86|CEDARVIEW|EVANSPORT/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'i386-linux' ));
	}

	# freebsd - try adding i386-linux which may work if linux compatibility is installed
	if ($^O =~ /freebsd/ && Slim::Utils::OSDetect->details->{'binArch'} =~ /i386|amd64/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'i386-linux' ));
	}

	$class->setMaxTracks;

	Plugins::Spotify::Settings->new;

	Plugins::Spotify::Radio->init;

	Plugins::Spotify::Library->init;

	Plugins::Spotify::Recent->load;

	# defer starting helper app until after pref based info is loaded to avoid saving empty prefs if interrupted
	Plugins::Spotify::Spotifyd->startD;

	Slim::Web::Pages->addPageFunction("^spotifyd.log", \&Plugins::Spotify::Spotifyd::logHandler);

	Plugins::Spotify::Image->init();

	Slim::Control::Request::addDispatch(['spotifyitemcmd',  'items', '_index', '_quantity' ], [0, 1, 1, \&itemCommand]);

	# create our own playlist command to allow playlist actions without setting title
	Slim::Control::Request::addDispatch(['spotifyplcmd'], [1, 0, 1, \&plCommand]);
}

sub postinitPlugin {
	require Plugins::Spotify::ProtocolHandler;

	# remove the logi handlers to avoid showing two entries in the context and search menus
	Slim::Menu::TrackInfo->deregisterInfoProvider('spotifylogi');

	# add here to replace any existing entry
	Slim::Control::Request::addDispatch(['spotify', 'star', '_uri', '_val'], [1, 0, 0, \&cliStar]);
}

sub shutdownPlugin {
	Plugins::Spotify::Recent->save('now');
	Plugins::Spotify::Spotifyd->shutdownD;
}

sub playerMenu { shift->can('nonSNApps') && $prefs->get('is_app') ? undef : 'RADIO' }

sub getDisplayName { 'PLUGIN_SPOTIFY' }

sub toplevel {
	my ($client, $callback, $args) = @_;

	my @menu = (
		{ name  => string('PLUGIN_SPOTIFY_TOP_100'), 
		  items => [
			  { name => string('ARTISTS'), type => 'link', url => \&level, passthrough => [ 'Search', { top => 'artists' } ], },
			  { name => string('ALBUMS'),  type => 'link', url => \&level, passthrough => [ 'Search', { top => 'albums'  } ], },
			  { name => string('PLUGIN_SPOTIFY_TRACKS'),   url => \&level, passthrough => [ 'Search', { top => 'tracks'  } ], 
				type => 'link', },
		 ] },
		{ name => string('PLUGIN_SPOTIFY_WHATS_NEW'),      url => \&level, passthrough => [ 'Search', { new => 1 } ], 
		  type => 'link', },
		{ name  => string('PLUGIN_SPOTIFY_LIBRARY'),
		  items => [
			  { name => string('ARTISTS'), url => \&Plugins::Spotify::Library::level, type => 'link', passthrough => [ 'artists' ], },
			  { name => string('ALBUMS'), url => \&Plugins::Spotify::Library::level, type => 'link', passthrough => [ 'albums' ], },
			  { name => string('PLUGIN_SPOTIFY_TRACKS'), url => \&Plugins::Spotify::Library::level, type => 'link',	passthrough => [ 'tracks' ], },
		  ] },
		{ name => string('PLAYLISTS'), type => 'link', url => \&level, passthrough => [ 'Playlists' ] },
		{ name => string('PLUGIN_SPOTIFY_RADIO'), type => 'link', url => \&Plugins::Spotify::Radio::level },
		{ name => string('PLUGIN_SPOTIFY_RECENT_ARTISTS'), url => \&Plugins::Spotify::Recent::level, passthrough => [ 'artists' ], type => 'link' },
		{ name => string('PLUGIN_SPOTIFY_RECENT_ALBUMS'), url => \&Plugins::Spotify::Recent::level, passthrough => [ 'albums' ], type => 'link' },
		{ name => string('PLUGIN_SPOTIFY_RECENT_SEARCHES'), url => \&Plugins::Spotify::Recent::level, passthrough => [ 'searches' ], type => 'link' },
	);

	if (my $user = $prefs->get('lastfmuser')) {
		push @menu, { name => string('PLUGIN_SPOTIFY_RECOMMENDED_ARTISTS'), 
					  url => \&level, passthrough => [ 'LastFM', { user => $user } ], type => 'link' };
	};

	push @menu, { name => string('PLUGIN_SPOTIFY_SEARCHURI'), type => 'search', url => \&wrapper };

	$callback->(\@menu);
}

sub level {
	my ($client, $callback, $args, $classid, $session) = @_;

	# for some reason we can get called via a TT template from the web interface, but with no args
	return if !defined $client && !defined $callback;

	my $class = 'Plugins::Spotify::' . $classid;

	eval "use $class";

	if ($@) {
		$log->error("$@");
		return;
	}

	$session ||= {};
	$session->{'ipeng'} ||= $args->{'params'}->{'userInterfaceIdiom'} && $args->{'params'}->{'userInterfaceIdiom'} =~ /iPeng/;
	$session->{'isWeb'} ||= $args->{'isWeb'};

	if (!defined $session->{'playalbum'}) {
		addPlayAlbum($client, $session);
	}

	$class->get($args, $session, $callback);
}

sub addPlayAlbum {
	my ($client, $session) = @_;

	# FIXME: do we want this - makes the web interface only play the selected track?
	if ($session->{'isWeb'}) {
		$session->{'playalbum'} = 0;
	}
	
	if (!exists $session->{'playalbum'} && $client) {
		$session->{'playalbum'} = $sprefs->client($client)->get('playtrackalbum');
	}
	
	# if player pref for playtrack album is not set, get the old server pref.
	if (!exists $session->{'playalbum'}) {
		$session->{'playalbum'} = $sprefs->get('playtrackalbum') ? 1 : 0;
	}
}

# wrapper around the level handler to allow spotify uris to be browsed to or search to be initiated
sub wrapper {
	my ($client, $callback, $args) = @_;

	my $search = $args->{'search'};

	# reformat http://open.spotify.com urls
	if ($search =~ /http:\/\/open\.spotify\.com\/(.*)/ || $search =~ /http:\/\/open spotify com\/(.*)/ ) {
		$search = "spotify:$1";
		$search =~ s/\//:/g;
	}

	if      ($search =~ /^spotify:track:/) {
		level($client, $callback, $args, 'TrackBrowse', { uri => $search });
	} elsif ($search =~ /^spotify:artist:/) {
		level($client, $callback, $args, 'ArtistBrowse', { artist => $search });
	} elsif ($search =~ /^spotify:album:/) {
		level($client, $callback, $args, 'AlbumBrowse', { album => $search });
	} elsif ($search =~ /^spotify:user:.*:playlist:/) {
		level($client, $callback, $args, 'SinglePlaylist', { uri => $search });
	} else {
		level($client, $callback, $args, 'Search', { search => 1 });
	}
}

# cli handler for browsing into items from web context menus
my $itemCommandSess = 0;
tie my %itemURICache, 'Tie::Cache::LRU', 10;
sub itemCommand {
	my $request = shift;

	my $client = $request->client;
	my $uri    = $request->getParam('uri');
	my $item_id= $request->getParam('item_id');
	my $command = $request->getRequest(0);
	my $connectionId = $request->connectionID;
	my $sess;

	# command xmlbrowser needs the session to be cached, add a session param so we can recurse into items
	if ($uri && $connectionId && !defined $item_id) {
		$itemCommandSess = ($itemCommandSess + 1) % 10;
		$sess = $itemCommandSess;
		$request->addParam('item_id', $sess);
		$itemURICache{ "$connectionId-$sess" } = $uri;
	}

	if (!$uri && $connectionId && $item_id) {
		($sess) = $item_id =~ /(\d+)\./;
		$uri = $itemURICache{ "$connectionId-$sess" };
	}

	my $feed = sub {
		my ($client, $callback, $args) = @_;
		if      ($uri =~ /^spotify:track:/) {
			level($client, $callback, $args, 'TrackBrowse', { uri => $uri });
		} elsif ($uri =~ /^spotify:artist:/) {
			level($client, $callback, $args, 'ArtistBrowse', { artist => $uri });
		} elsif ($uri =~ /^spotify:album:/) {
			level($client, $callback, $args, 'AlbumBrowse', { album => $uri });
		}
	};

	# wrap feed in another level if we have added the $sess value in the item_id
	my $wrapper = defined $sess ? sub {
		my ($client, $callback, $args) = @_;
		my $array = [];
		$array->[$sess] = { url => $feed, type => 'link' };
		$callback->($array);
	} : undef;

	Slim::Control::XMLBrowser::cliQuery($command, $wrapper || $feed, $request);
}

sub plCommand {
	my $request = shift;

	my $client = $request->client;
	my $cmd    = $request->getParam('cmd');
	my $uri    = $request->getParam('uri');
	my $playuri= $request->getParam('playuri');
	my $ind    = $request->getParam('ind');
	my $top    = $request->getParam('top');

	$log->info("pl: $cmd uri: $uri play: $playuri ind: $ind top: $top");

	if ($cmd eq 'load') {
		$uri = $playuri || $uri;
	}

	my $query;

	if ($uri =~ /^spotify:track|^spotify:album/) {
		$query = "$uri/browse.json";
	} elsif ($uri =~ /^spotify:artist/) {
		$query = "$uri/tracks.json";
		if ($top) {
			my $max = 2 * $top; # some additional to allow for duplicate filtering
			$query .= "?max=$max";
		}
	} elsif ($uri =~ /^spotify:user:.*:playlist:|starred|inbox/) {
		$query = "$uri/playlists.json";
	} elsif ($uri eq 'toptracks') {
		$query = "toplist.json?q=tracks&r=" . ($prefs->get('location') || 'user');
	}
	
	if ($query) {
	
		$log->info("fetching play info: $query");

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $json = eval { from_json($_[0]->content) };
				if ($@) {
					$log->warn("bad json: $@");
					return;
				}
	
				# update recent data
				if ($uri =~ /^spotify:artist/) {
					Plugins::Spotify::Recent->updateRecentArtists($json->{'artist'}, $json->{'artisturi'});
				} elsif ($uri =~ /^spotify:album/) {
					Plugins::Spotify::Recent->updateRecentArtists($json->{'artist'}, $json->{'artisturi'}); 
					Plugins::Spotify::Recent->updateRecentAlbums($json->{'artist'}, $json->{'album'}, $json->{'uri'}, $json->{'cover'});
				}
			
				# find top X non duplicated tracks for toplist playback
				if ($top && $json->{'tracks'}) {
					my @tracks; 
					my $names = {};
					for (@{$json->{'tracks'}}) {
						next if $names->{ $_->{'name'} };
						push @tracks, $_;
						$names->{ $_->{'name'} } = 1;
						last if scalar @tracks == $top;
					}
					$json->{'tracks'} = \@tracks;
				}
						
				my @objs;

				for my $track (@{ $json->{'tracks'} || [ $json ] }) {

					my $obj = Slim::Schema::RemoteTrack->updateOrCreate($track->{'uri'}, {
						title   => $track->{'name'},
						artist  => $track->{'artist'},
						album   => $track->{'album'},
						secs    => $track->{'duration'} / 1000,
						cover   => $track->{'cover'},
						tracknum=> $track->{'index'},
					});

					$obj->stash->{'starred'} = $track->{'starred'};

					push @objs, $obj;
				}

				$log->info("${cmd}ing " . scalar @objs . " tracks" . ($ind ? " starting at $ind" : ""));

				$client->execute([ 'playlist', "${cmd}tracks", 'listref', \@objs, undef, $ind ]);
			},

			sub { $log->warn("error: $_[1]") }

		)->get(Plugins::Spotify::Spotifyd->uri($query));
	}
}

sub setMaxTracks {
	# change the size of the LRU caches used within S:S:RemoteTrack as we load entire playlists at once
	# and the server playlist code assumes it can find all tracks in the playlist within the db 
	my $remoteTrackLRUCache = tied %Slim::Schema::RemoteTrack::Cache;
	my $remoteTrackLRUidIndex = tied %Slim::Schema::RemoteTrack::idIndex;
	my $largeImageMap = tied %Plugins::Spotify::Image::largeImageMap;

	my $size = $prefs->get('maxtracks');

	$remoteTrackLRUCache->max_size($size);	
	$remoteTrackLRUidIndex->max_size($size);
	$largeImageMap->max_size($size);
}

sub cliStar {
	my $request = shift;
 
	my $client = $request->client;
	my $uri = $request->getParam('_uri');
	my $val = $request->getParam('_val');

	$uri =~ s{^spotify://}{spotify:};
	$val = 0 if !defined $val;

	# don't process from web interface as its still a shuffle button
	if ($request->source ne 'JSONRPC') {

		$log->info("setting starred value for $uri to $val");
		
		Plugins::Spotify::Spotifyd->get("$uri/star.json?s=$val", sub {}, sub {});
		
		Plugins::Spotify::ProtocolHandler->getMetadataFor($client, $uri, undef, 1);
	}
																
	$request->setStatusDone;
}

1;
