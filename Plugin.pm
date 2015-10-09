package Plugins::Spotify::Plugin;

# Plugin to play spotify streams using helper app & libspotify
#
# (c) Adrian Smith (Triode), 2010, 2011 - see license.txt for details
#
# The plugin relies on a separate binary spotifyd which is linked to libspotify

use strict;

use vars qw(@ISA);

use JSON::XS::VersionOneAndTwo;
use File::Spec::Functions;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Slim::Utils::Strings qw(string cstring);

use Plugins::Spotify::Settings;
use Plugins::Spotify::Spotifyd;
use Plugins::Spotify::Image;
use Plugins::Spotify::ContextMenu;
use Plugins::Spotify::Radio;
use Plugins::Spotify::Library;
use Plugins::Spotify::Recent;

my $log;
my $compat;
my $prefs  = preferences('plugin.spotify');
my $sprefs = preferences('server');

BEGIN {
	$log = Slim::Utils::Log->addLogCategory({
		'category'     => 'plugin.spotify',
		'defaultLevel' => 'WARN',
		'description'  => string('PLUGIN_SPOTIFY'),
	}); 

	# Always use OneBrowser version of XMLBrowser by using server or packaged version included with plugin
	if (exists &Slim::Control::XMLBrowser::findAction) {
		$log->info("using server XMLBrowser");
		require Slim::Plugin::OPMLBased;
		push @ISA, 'Slim::Plugin::OPMLBased';
	} else {
		$log->info("using packaged XMLBrowser: Slim76Compat");
		require Slim76Compat::Plugin::OPMLBased;
		push @ISA, 'Slim76Compat::Plugin::OPMLBased';
		$compat = 1;
	}
}

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

	Plugins::Spotify::ContextMenu->init;

	Plugins::Spotify::Radio->init;

	Plugins::Spotify::Library->init;

	Plugins::Spotify::Recent->load;

	# defer starting helper app until after pref based info is loaded to avoid saving empty prefs if interrupted
	Plugins::Spotify::Spotifyd->startD;

	Slim::Web::Pages->addPageFunction("^spotifyd.log", \&Plugins::Spotify::Spotifyd::logHandler);

	Plugins::Spotify::Image->init();

	Slim::Menu::TrackInfo->registerInfoProvider( spotify => (
		after => 'middle',
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( spotifystar => (
		before => 'addtrack',
		func  => \&trackInfoMenuStar,
	) );

	# override built in track info provider - note this handles all urls
	Slim::Menu::TrackInfo->registerInfoProvider( contributors => (
		after => 'top',
		func  => \&trackInfoContributorsMenu,
	) );

	# override built in track info provider - note this handles all urls
	Slim::Menu::TrackInfo->registerInfoProvider( album => (
		after => 'contributors',
		func  => \&trackInfoAlbumMenu,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( spotifylibrary => (
		after     => 'spotifystar',
		func      => \&trackInfoLibraryMenu,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( spotifyplaylist => (
		after     => 'spotifylibrary',
		func      => \&trackInfoPlaylistMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( spotify => (
		after => 'middle',
		func  => \&artistInfoMenu,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( spotify => (
		after => 'middle',
		name  => 'PLUGIN_SPOTIFY',
		func  => \&searchInfoMenu,
	) );

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

sub compat { $compat }

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

	# if called from 7.5 native xmlbrowser we will have no args hash, also wrap callback as 7.5 xmlbrowser expects array refs
	if ($compat && (!ref $args || ref $args ne 'HASH')) {
		my $cb;
		($client, $cb, $classid, $session) = @_;
		$args = {};
		$callback = sub { $cb->(ref $_[0] && ref $_[0] eq 'HASH' ?  $_[0]->{'items'} : $_[0] ) };
	}

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

	# call xmlbrowser using compat version if necessary
	if (!$compat) {
		Slim::Control::XMLBrowser::cliQuery($command, $wrapper || $feed, $request);
	} else {
		Slim76Compat::Control::XMLBrowser::cliQuery($command, $wrapper || $feed, $request);
	}
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

				if (!$compat) {
					$client->execute([ 'playlist', "${cmd}tracks", 'listref', \@objs, undef, $ind ]);
				} else {
					$client->execute([ 'playlist', "${cmd}tracks", 'listref', \@objs ]);
					if ($cmd eq 'load' && $ind) {
						$client->execute([ 'playlist', 'jump', $ind ]);
					}
				}
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

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;
	
	return unless $client;
	
	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album}  : ( $track->album ? $track->album->name : undef );
	my $title  = $track->remote ? $remoteMeta->{title}  : $track->title;

	my @menu;

	if ($artist) {
		push @menu, {
			name        => cstring($client, 'ARTIST') . ": " . $artist,
			url         => \&level,
			passthrough => [ 'Search', { query => "artist:\"$artist\"", artistsearch => 1, exact => 1 } ],
			type        => 'link',
			favorites   => 0,
		},
	};

	if ($album) {
		push @menu, {
			name        => cstring($client, 'ALBUM') . ": " . $album,
			url         => \&level,
			passthrough => [ 'Search', { query => "album:\"$album\"", albumsearch => 1, exact => 1 } ],
			type        => 'link',
			favorites   => 0,
		},
	};

	if ($track) {
		push @menu, {
			name        => cstring($client, 'TRACK') . ": " . $title,
			url         => \&level,
			passthrough => [ 'Search', { query => "track:\"$title\" AND artist:\"$artist\"", tracksearch => 1, exact => 1 } ],
			type        => 'link',
			favorites   => 0,
		},
	};

	if (scalar @menu) {
		return {
			name  => string('PLUGIN_SPOTIFY_ON_SPOTIFY'),
			items => \@menu,
		};
	}

	return undef;
}

sub trackInfoMenuStar {
	my ($client, $url, $track, $remoteMeta) = @_;

	return unless $url =~ /^spotify:track/;

	my $starred = Plugins::Spotify::ProtocolHandler->getMetadataFor($client, $url)->{'starred'};

	return {
		name => string($starred ? 'PLUGIN_SPOTIFY_STARRED' : 'PLUGIN_SPOTIFY_NOTSTARRED'),
		url  => sub {
			my ($client, $cb) = @_;
			# in onebrowser we can get called from the template - return without processing
			return unless $client;
			$client->execute([ 'spotify', 'star', $url, $starred ? 0 : 1 ]);
			my $resp = { showBriefly => 1, popback => 2, type => 'text',
						 name => string($starred ? 'PLUGIN_SPOTIFY_STAR_REMOVED' : 'PLUGIN_SPOTIFY_STAR_ADDED') };
			$cb->([$resp]);
		},
		type => 'link',
		nextWindow => 'parent',
		forceRefresh => 1,
		favorites => 0,
	};
}

sub trackInfoContributorsMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	# use built in handler for all track types other than spotify
	if ($url !~ /^spotify:track/) {
		return Slim::Menu::TrackInfo::infoContributors(@_);
	}

	if ($remoteMeta->{'artistA'}) {

		my @items;

		for my $artist (@{$remoteMeta->{'artistA'}}) {
			push @items, {
				type        => 'link',
				name        => $artist->{'name'},
				label       => 'ARTIST',
				url         => 'anyurl',
				itemActions => Plugins::Spotify::ParserBase->actions({ items => 1, uri => $artist->{'uri'} }),
			};
		}

		return \@items;
	}
}

sub trackInfoAlbumMenu {
	my ($client, $url, $track, $remoteMeta) = @_;
	
	# use built in handler for all track types other than spotify
	if ($url !~ /^spotify:track/) {
		return Slim::Menu::TrackInfo::infoAlbum(@_);
	}

	if ($remoteMeta->{'album'} && $remoteMeta->{'albumuri'}) {
		return {
			type        => 'link',
			name        => $remoteMeta->{'album'},
			label       => 'ALBUM',
			url         => 'anyurl',
			itemActions => Plugins::Spotify::ParserBase->actions({ items => 1, uri => $remoteMeta->{'albumuri'} }),
			favorites   => 0,
		};
	}
}

sub trackInfoLibraryMenu {
	my ($client, $url, $track, $remoteMeta) = @_;
	
	return unless $url =~ /^spotify:track/ && $remoteMeta && $remoteMeta->{'albumuri'};

	my ($cover) = $remoteMeta->{'cover'} =~ /(spotify:image:.*)\//;
	
	# wrapper around our context menu, recreate track info hash for this
	my $info = {
		starred  => $remoteMeta->{'starred'},
		name     => $remoteMeta->{'title'},
		albumuri => $remoteMeta->{'albumuri'},
		duration => $remoteMeta->{'duration'},
		uri      => $url,
		album    => $remoteMeta->{'album'},
		cover    => $cover,
		artists  => $remoteMeta->{'artistA'},
	};
	
	return Plugins::Spotify::ContextMenu::library($client, $url, { uri => $url }, $info);
}

sub trackInfoPlaylistMenu {
	my ($client, $url, $track, $remoteMeta) = @_;
	
	return unless $url =~ /^spotify:track/ && $remoteMeta && $remoteMeta->{'albumuri'};

	my ($cover) = $remoteMeta->{'cover'} =~ /(spotify:image:.*)\//;
	
	# wrapper around our context menu, recreate track info hash for this
	my $info = {
		starred  => $remoteMeta->{'starred'},
		name     => $remoteMeta->{'title'},
		albumuri => $remoteMeta->{'albumuri'},
		duration => $remoteMeta->{'duration'},
		uri      => $url,
		album    => $remoteMeta->{'album'},
		cover    => $cover,
		artists  => $remoteMeta->{'artistA'},
	};
	
	return Plugins::Spotify::ContextMenu::playlist($client, $url, { uri => $url }, $info);
}

sub artistInfoMenu {
	my ($client, $url, $obj, $remoteMeta) = @_;

	my $artist = $obj && $obj->name;

	if ($artist) {
		return {
			name        => string('PLUGIN_SPOTIFY_ON_SPOTIFY'),
			url         => \&level,
			passthrough => [ 'Search', { query => $artist, artistsearch => 1, exact => 1 } ],
			type        => 'link',	
			favorites   => 0,
		};
	}
}

sub searchInfoMenu {
	my ($client, $tags) = @_;

	my $query = $tags->{'search'};

	return {
		name => string('PLUGIN_SPOTIFY'),
		search => $query,
		items => [
			{
				name   => string('PLUGIN_SPOTIFY_SEARCH_ARTISTS'),
				url    => \&level,
				passthrough => [ 'Search', { query => $query, artistsearch => 1 } ],
				search => $query,
			},
			{
				name   => string('PLUGIN_SPOTIFY_SEARCH_ALBUMS'),
				url    => \&level,
				passthrough => [ 'Search', { query => $query, albumsearch => 1 } ],
				search => $query,
			},
			{
				name   => string('PLUGIN_SPOTIFY_SEARCH_TRACKS'),
				url    => \&level,
				passthrough => [ 'Search', { query => $query, tracksearch => 1 } ],
				search => $query,
			},
		],
	};
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
