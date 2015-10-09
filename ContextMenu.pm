package Plugins::Spotify::ContextMenu;

use strict;
use warnings;

use base qw(Slim::Menu::Base);

use URI::Escape;

use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Spotify::ContextMenuParser;
use Plugins::Spotify::Library;

use constant MENU => \&Plugins::Spotify::Plugin::level;

my $log    = logger('plugin.spotify');
my $prefs  = preferences('plugin.spotify');

sub init {
	my $class = shift;

	$class->SUPER::init;

	Slim::Control::Request::addDispatch(['spotifyinfocmd', 'items', '_index', '_quantity' ], [0, 1, 1, \&infoCommand]);
}

sub name {
	return 'PLUGIN_SPOTIFY';
}

sub registerDefaultInfoProviders {
	my $class = shift;
	
	$class->SUPER::registerDefaultInfoProviders();

	$class->registerInfoProvider( spotifystar => (
		after     => 'top',
		func      => \&star,
	) );
	$class->registerInfoProvider( spotifyplaylist1 => (
		after     => 'spotifystar',
		func      => sub { playlist(@_, 1) },
	) );
	$class->registerInfoProvider( addspotifyitem => (
		menuMode  => 1,
		after     => 'spotifyplaylist1',
		func      => \&addItemEnd,
	) );
	$class->registerInfoProvider( addspotifyitemnext => (
		menuMode  => 1,
		after     => 'addspotifyitem',
		func      => \&addItemNext,
	) );
	$class->registerInfoProvider( playspotifyitem => (
		menuMode  => 1,
		after     => 'addspotifyitemnext',
		func      => \&playItem,
	) );
	$class->registerInfoProvider( spotifylibrary => (
		after     => 'middle',
		func      => \&library,
	) );
	$class->registerInfoProvider( spotifyplaylist2 => (
		after     => 'spotifylibrary',
		func      => sub { playlist(@_, 2) },
	) );
	$class->registerInfoProvider( spotifyinfo => (
		after     => 'spotifyplaylist2',
		func      => \&info,
	) );
}

sub menu {
	my ($class, $client, $uri, $tags, $contextInfo) = @_;

	my $infoOrdering = $class->getInfoOrdering;
	
	# Function to add menu items
	my $addItem = sub {
		my ( $ref, $items ) = @_;
		
		if ( defined $ref->{func} ) {
			
			# nb functions are called with different params from normal SBS context menus
			my $item = eval { $ref->{func}->($client, $uri, $tags, $contextInfo) };
			if ( $@ ) {
				$log->error( 'spotifyinfo menu item "' . $ref->{name} . '" failed: ' . $@ );
				return;
			}
			
			return unless defined $item;
			
			# skip jive-only items for non-jive UIs
			return if $ref->{menuMode} && !$tags->{menuMode};
			
			if ( ref $item eq 'ARRAY' ) {
				if ( scalar @{$item} ) {
					push @{$items}, @{$item};
				}
			}
			elsif ( ref $item eq 'HASH' ) {
				if ( scalar keys %{$item} ) {
					push @{$items}, $item;
				}
			}
			else {
				$log->error('spotifyinfo menu item "' . $ref->{name} . '" failed: not an arrayref or hashref' );
			}				
		}
	};
	
	# Now run the order, which generates all the items we need
	my $items = [];
	
	for my $ref ( @{ $infoOrdering } ) {
		# Skip items with a defined parent, they are handled
		# as children below
		next if $ref->{parent};
		
		# Add the item
		$addItem->( $ref, $items );
		
		# Look for children of this item
		my @children = grep {
			$_->{parent} && $_->{parent} eq $ref->{name}
		} @{ $infoOrdering };
		
		if ( @children ) {
			my $subitems = $items->[-1]->{items} = [];
			
			for my $child ( @children ) {
				$addItem->( $child, $subitems );
			}
		}
	}

	my $ret = {
		name  => $contextInfo->{'name'},
		play  => $uri,
		cover => $contextInfo->{'coverart'},
		type  => 'opml',
		items => $items,
		menuComplete => 1,
	};

	return $ret;
}

sub star {
	my ($client, $uri, $tags, $contextInfo) = @_;

	return unless $uri =~ /^spotify:track/;

	my $starred = $contextInfo->{'starred'};

	return [ {
		name => cstring($client, $starred ? 'PLUGIN_SPOTIFY_STARRED' : 'PLUGIN_SPOTIFY_NOTSTARRED'),
		url  => sub {
			my ($client, $cb) = @_;
			# in onebrowser we can get called from the template - return without processing
			return unless $client;
			$client->execute([ 'spotify', 'star', $uri, $starred ? 0 : 1 ]);
			my $resp = { showBriefly => 1, popback => 2, type => 'text',
						 name => cstring($client, $starred ? 'PLUGIN_SPOTIFY_STAR_REMOVED' : 'PLUGIN_SPOTIFY_STAR_ADDED') };
			$cb->([$resp]);
		},
		type => 'link',
		nextWindow => 'parent',
		forceRefresh => 1,
		favorites => 0,
	} ];
}

sub _entry {
	my ($cmd, $uri) = @_;
	return {
		player => 0,
		cmd => [ 'spotifyplcmd' ],
		params => {
			cmd => $cmd,
			uri => $uri,
		},
		nextWindow => $cmd eq 'load' ? 'nowPlaying' :'parent',
	}
}

sub addItemEnd {
	my ($client, $uri, $tags, $contextInfo) = @_;

	my $action = _entry('add', $uri);

	return { 
		name => cstring($client, 'ADD'),
		type => 'text', 
		jive => {
			style => 'itemplay',
			actions => { 
				go   => $action,
				add  => $action,
				play => $action,
			},	 
		},
	};
}

sub addItemNext {
	my ($client, $uri, $tags, $contextInfo) = @_;

	my $action = _entry('insert', $uri);

	return { 
		name => cstring($client, 'PLAY_NEXT'),
		type => 'text', 
		jive => {
			style => 'itemplay',
			actions => { 
				go   => $action,
				add  => $action,
				play => $action,
			},	 
		},
	};
}

sub playItem {
	my ($client, $uri, $tags, $contextInfo) = @_;

	my $action = _entry('load', $uri);

	return { 
		name => cstring($client, 'PLAY'),
		type => 'text', 
		jive => {
			style => 'itemplay',
			actions => { 
				go   => $action,
				play => $action,
			},	 
		},
	};
}

sub info {
	my ($client, $uri, $tags, $info) = @_;

	my @info;

	if ($uri =~ /^spotify:track/) {

 		my @artists;
		for my $artist (@{$info->{'artists'}}) {
			push @artists, {
				type        => 'link',
				name        => $artist->{'name'},
				label       => 'ARTIST',
				url         => 'anyurl',
				itemActions => Plugins::Spotify::ParserBase->actions({ items => 1, uri => $artist->{'uri'} }),
			};
		}

		my $secs = $info->{'duration'} / 1000;
		@info = (
			{ type => 'text', label => 'TRACK',  name => $info->{'name'} },
			@artists,
			{ type => 'link', label => 'ALBUM',  name => $info->{'album'}, url  => 'anyurl', 
			  itemActions => Plugins::Spotify::ParserBase->actions({ items => 1, uri => $info->{'albumuri'} }),
		    },
			{ type => 'text', label => 'LENGTH', name => sprintf('%s:%02s', int($secs / 60), $secs % 60) },
			{ type => 'text', label => 'URL',    name => $uri },
		);
		$info->{'coverart'} = Plugins::Spotify::Image->uri($info->{'cover'});

	} elsif ($uri =~ /^spotify:album/) {

		@info = (
			{ type => 'link', label => 'ARTIST', name => $info->{'artist'}, url => 'anyurl', 
			  itemActions => Plugins::Spotify::ParserBase->actions({ items => 1, uri => $info->{'artisturi'} }),
			},
			{ type => 'link', label => 'ALBUM',  name => $info->{'album'} },
			{ type => 'text', label => 'URL',    name => $uri },
		);
		$info->{'coverart'} = Plugins::Spotify::Image->uri($info->{'cover'});
		$info->{'name'} = $info->{'album'};

	} elsif ($uri =~ /^spotify:artist/) {

		@info = (
			{ type => 'link', label => 'ARTIST', name => $info->{'artist'}, url => 'anyurl',
			  itemActions => Plugins::Spotify::ParserBase->actions({ items => 1, uri => $info->{'artisturi'} }),
		    },
			{ type => 'text', label => 'URL',    name => $uri },
		);
		if ($info->{'artistimages'} && scalar @{$info->{'artistimages'}} >= 1) {
			$info->{'coverart'} = Plugins::Spotify::Image->uri($info->{'artistimages'}->[0]);
		}
		$info->{'name'} = $info->{'artist'};

	} elsif ($uri =~ /^spotify:user:.*:playlist/) {

		@info = (
			{ type => 'text', label => 'PLAYLIST', name => $info->{'name'} },
			{ type => 'text', label => 'TRACKS',   name => scalar @{ $info->{'tracks'} || [] } },
			{ type => 'text', label => 'URL',      name => $info->{'uri'} },
		);
	}

	return \@info;
}

sub library {
	my ($client, $uri, $tags, $info) = @_;

	my @entries; my @menu;

	if ($uri =~ /^spotify:artist/) {

		if (!Plugins::Spotify::Library->contains($uri)) {
			push @entries, [ 'ADD_ARTIST', 'addArtist', undef, $info->{'artist'}, $uri ];
		} else {
			push @entries, [ 'REMOVE_ARTIST', 'delArtist', undef, $uri ];
		}

	} elsif ($uri =~ /^spotify:album/) {

		if (!Plugins::Spotify::Library->contains($uri)) {
			push @entries, [ 'ADD_ALBUM', 'addAlbum', undef, $info->{'album'}, $info->{'artist'}, $uri, $info->{'cover'} ];
		} else {
			push @entries, [ 'REMOVE_ALBUM', 'delAlbum', undef, $uri ];
		}

	} elsif ($uri =~ /^spotify:track/) {

		my @artists;

		for my $artist (@{$info->{'artists'}}) {
			push @artists, $artist->{'name'};
		}

		if (!Plugins::Spotify::Library->contains($uri)) {
			push @entries, [ 'ADD_TRACK', 'addTrack', undef,
							 $info->{'name'}, $info->{'album'}, join(", ", @artists), $uri, $info->{'cover'} ];
		} else {
			push @entries, [ 'REMOVE_TRACK', 'delTrack', undef, $uri ];
		}

		if ($info->{'albumuri'}) {
			if (!Plugins::Spotify::Library->contains($info->{'albumuri'})) {
				push @entries, [ 'ADD_ALBUM', 'addAlbum', undef, 
								 $info->{'album'}, join(", ", @artists), $info->{'albumuri'}, $info->{'cover'}];
			} else {
				push @entries, [ 'REMOVE_ALBUM', 'delAlbum', undef, $info->{'albumuri'} ];
			}
		}

		my $show = (scalar @{$info->{'artists'}} > 1);

		for my $artist (@{ $info->{'artists'} }) {
			if (!Plugins::Spotify::Library->contains($artist->{'uri'})) {
				push @entries, [ 'ADD_ARTIST', 'addArtist', $show ? $artist->{'name'} : undef, $artist->{'name'}, $artist->{'uri'} ];
			} else {
				push @entries, [ 'REMOVE_ARTIST', 'delAlbum', $show ? $artist->{'name'}: undef, $artist->{'uri'} ];
			}
		}

	} else {
		return;
	}

	for my $entry (@entries) {

		my ($string, $action, $show, @pt) = @$entry;

		push @menu, {
			name => sprintf(cstring($client, 'PLUGIN_SPOTIFY_LIBRARY_' . $string . ($show ? '_NAME' : '')), $show),
			url  => sub {
				my (undef, $callback) = @_;
				$log->info("libary $action");
				Plugins::Spotify::Library->$action(@pt);
				$callback->( [{
					type        => 'text',
					name        => cstring($client, $string =~ /ADD/ ? 'PLUGIN_SPOTIFY_ADDED' : 'PLUGIN_SPOTIFY_REMOVED'),
					popback     => 2,
					refresh     => 1,
					showBriefly => 1,
					favorites   => 0,
				}] );
			},
			'type' => 'link',
			'favorites'  => 0,
			'nextWindow' => 'parent',
		};
	}

	return \@menu;
}

sub playlist {
	my ($client, $uri, $tags, $info, $pos) = @_;

	# playlist entries can appear before (pos 1) or after (pos 2) library entries
	# pos 1 is used when the current item is an owned playlist which can be delted from
	$pos ||= 2;

	my $playlist = $tags->{'playlist'};

	my @playlists;

	my $msg = sub {
		my $string = shift;
		my $pop = shift || 2;
		return [ {
			type        => 'text',
			name        => Slim::Utils::Strings::getString($string),
			popback     => $pop,
			refresh     => 1,
			showBriefly => 1,
			favorites   => 0,
		} ];
	};

	# we can add tracks or albums to existing playlists - either create new or add to existing
	if ($pos == 2 && !$playlist && $uri =~ /^spotify:track|^spotify:album/) {
		
		my $obj = $uri =~ /^spotify:track/ ? 'track' : 'album';

		push @playlists, {
			'name' => cstring($client, 'PLUGIN_SPOTIFY_PLAYLIST_ADD_NEW_' . uc($obj)),
			'url'  => sub {
				my (undef, $callback, $args) = @_;
				my $name = URI::Escape::uri_escape_utf8($args->{'search'});
				Plugins::Spotify::Spotifyd->get(
					"playlistedit.json?a=create_playlist&n=$name",
					sub {
						my $pl_uri = shift;
						$log->info("playlist $name $pl_uri created - adding $obj");
						Plugins::Spotify::Spotifyd->get(
							"$pl_uri/playlistedit.json?a=add_$obj&u=$uri",
							sub {
								$log->info("added $obj to playlist $pl_uri");
								$callback->($msg->('PLUGIN_SPOTIFY_ADDED_TO_PLAYLIST', 3));
							},
							sub { $log->warn($_[0]); $callback->($msg->($_[0])); },
						);
					},
					sub { $log->warn($_[0]); $callback->($msg->($_[0])); },
				);
			},
			'type' => 'search',
			'nextWindow' => 'parent',
		};

		push @playlists, {
			'name' => cstring($client, 'PLUGIN_SPOTIFY_PLAYLIST_ADD_' . uc($obj)),
			'url'  => sub {
				my (undef, $callback, $args) = @_;
				# get the playlists, ignoring folders
				Plugins::Spotify::Spotifyd->get(
					"playlists.json",
					sub {
						my $json = shift;
						my @menu;
						for my $pl (@{ $json->{'playlists'} }) {
							if ($pl->{'uri'}) {
								# build menu of available playlists to add obj to
								push @menu, {
									'name' => $pl->{'name'},
									'url'  => sub { 
										my (undef, $cb, $args) = @_;
										$log->info("adding $obj to playlist $pl->{uri}");
										Plugins::Spotify::Spotifyd->get(
											"$pl->{uri}/playlistedit.json?a=add_$obj&u=$uri",
											sub {
												$log->info("added $obj to playlist $pl->{uri}");
												$cb->($msg->('PLUGIN_SPOTIFY_ADDED_TO_PLAYLIST', 3));
											},
											sub { $log->warn($_[0]); $cb->($msg->($_[0])); },
										);
									},
									'type' => 'link',
									'nextWindow' => $tags->{'menuMode'} ? 'grandparent' : undef,
								};
							}
						}
						$callback->(\@menu);
					},
					sub { $log->warn($_[0]); $callback->($msg->($_[0])); },
				);
			},
			'type' => 'link',
			'isContextMenu' => $tags->{'menuMode'} ? 1 : undef,
		};
	}

	# if this is a playlist offer to rename delete
	if ($pos == 2 && $uri =~ /spotify:user:.*:playlist/) {

		push @playlists, {
			'name' => cstring($client, 'PLUGIN_SPOTIFY_PLAYLIST_RENAME'),
			'url'  => sub {
				my (undef, $callback, $args) = @_;
				$log->info("renaming playlist $uri to $args->{search}");
				my $name = URI::Escape::uri_escape_utf8($args->{'search'});
				Plugins::Spotify::Spotifyd->get(
					"$uri/playlistedit.json?a=rename&n=$name",
					sub {
						$callback->($msg->('PLUGIN_SPOTIFY_PLAYLIST_RENAMED', 4));
					},
					sub { $log->warn($_[0]); $callback->($msg->($_[0])); },
				);
			},
			'type' => 'search',
			'nextWindow' => 'parent',
			'isContextMenu' => $tags->{'menuMode'} ? 1 : undef,
		};

		push @playlists, {
			'name' => cstring($client, 'PLUGIN_SPOTIFY_PLAYLIST_DELETE'),
			'items' => [
				{ name => cstring($client, 'CANCEL'),
				  url  => sub {
					  my (undef, $callback, $args) = @_;
					  $callback->($msg->('PLUGIN_SPOTIFY_PLAYLIST_CANCELLED', 3));
				  },
				  type => 'link',
				  nextWindow => $tags->{'menuMode'} ? 'grandparent' : undef,
				  isContextMenu => $tags->{'menuMode'} ? 1 : undef,
			    },
				{ name => sprintf(cstring($client, 'PLUGIN_SPOTIFY_PLAYLIST_DELETE_NAME'), $info->{'name'}),
				  url  => sub {
					  my (undef, $callback, $args) = @_;
					  Plugins::Spotify::Spotifyd->get(
						  "$uri/playlistedit.json?a=delete_playlist",
						  sub {
							  $callback->($msg->('PLUGIN_SPOTIFY_PLAYLIST_DELETED', 4));
						  },
						  sub { $log->warn($_[0]); $callback->($msg->($_[0])); },
					  );
				  },
				  type => 'link',
				  nextWindow => $tags->{'menuMode'} ? 'grandparent' : undef,
				  isContextMenu => $tags->{'menuMode'} ? 1 : undef,
			    },
			],
			'type' => 'link',
			'isContextMenu' => $tags->{'menuMode'} ? 1 : undef,
		};

	}

	if ($pos == 1 && $playlist && $uri =~ /^spotify:track/) {

		push @playlists, {
			'name' => cstring($client, 'PLUGIN_SPOTIFY_PLAYLIST_DELETE_TRACK'),
			'items' => [
				{ name => cstring($client, 'CANCEL'),
				  url  => sub {
					  my (undef, $callback, $args) = @_;
					  $callback->($msg->('PLUGIN_SPOTIFY_PLAYLIST_CANCELLED', 3));
				  },
				  type => 'link',
				  nextWindow => $tags->{'menuMode'} ? 'grandparent' : undef,
				  isContextMenu => $tags->{'menuMode'} ? 1 : undef,
			    },
				{ name => sprintf(cstring($client, 'PLUGIN_SPOTIFY_PLAYLIST_DELETE_NAME'), $info->{'name'}),
				  url  => sub {
					  my (undef, $callback, $args) = @_;
					  Plugins::Spotify::Spotifyd->get(
						  "$playlist/playlistedit.json?a=delete_track&u=$uri",
						  sub {
							  $callback->($msg->('PLUGIN_SPOTIFY_PLAYLIST_TRACK_DELETED', 3));
						  },
						  sub { $log->warn($_[0]); $callback->($msg->($_[0])); },
					  );
				  },
				  type => 'link',
				  nextWindow => $tags->{'menuMode'} ? 'grandparent' : undef,
				  isContextMenu => $tags->{'menuMode'} ? 1 : undef,
			    },
			],
			'type' => 'link',
			'isContextMenu' => $tags->{'menuMode'} ? 1 : undef,
		};

	}

	return \@playlists;
}

# keep a small cache of feeds params to allow browsing into feeds
my $infoCommandSess = 0;
tie my %cachedFeed, 'Tie::Cache::LRU', 10;
sub infoCommand {
	my $request = shift;

	# propogate hack from server...  needed as some interface don't add _index & _quantity
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	if ( $index =~ /(.*?):(.*)/ ) {
		$request->addParam($1, $2);
		$index = 0;
		$request->addParam('_index', $index);
	}
	if ( $quantity =~ /(.*?):(.*)/ ) {
		$request->addParam($1, $2);
		$quantity = 200;
		$request->addParam('_quantity', $quantity);
	}

	my $client   = $request->client;
	my $command  = $request->getRequest(0);
	my $uri      = $request->getParam('uri');
	my $playlist = $request->getParam('playlist');
	my $menuMode = $request->getParam('menu') || 0;
	my $item_id  = $request->getParam('item_id');
	my $connectionId = $request->connectionID;
	my $sess;
	my $cacheKey;

	my $tags = {
		menuMode => $menuMode,
		uri      => $uri,
		playlist => $playlist,
	};

	# command xmlbrowser needs the session to be cached, add a session param so we can recurse into items
	if ($uri && $connectionId && !defined $item_id) {
		$infoCommandSess = ($infoCommandSess + 1) % 10;
		$sess = $infoCommandSess;
		$request->addParam('item_id', $sess);
		$cacheKey = "$connectionId-$sess";
	}

	if (!$uri && $connectionId && $item_id) {
		($sess) = $item_id =~ /(\d+)\./;
		$cacheKey = "$connectionId-$sess";
	}

	# button and web interfaces
	if (!$cacheKey && $uri) {
		$cacheKey = "$client-$uri-" . ($playlist || '');
	}

	# Hack to show progress animation on button interface while we fetch some context info
	my $showBlock = (caller(4) =~ /Button/);

	if ($uri) {
		
		$log->info("info request for: $uri cache key: $cacheKey");
		
		$request->setStatusProcessing;
		
		my $contextCB = sub {
			my $contextInfo = shift;

			$cachedFeed{ $cacheKey } = [ $client, $uri, $tags, $contextInfo ];

			my $feed = __PACKAGE__->menu($client, $uri, $tags, $contextInfo);

			$client->unblock() if $showBlock;

			# wrap feed in another level if we have added the $sess value in the item_id
			my $wrapper = defined $sess ? sub {
				my ($client, $callback, $args) = @_;
				my $array = [];
				$array->[$sess] = $feed;
				$callback->($array);
			} : undef;
			
			# call xmlbrowser using compat version if necessary
			if (!Plugins::Spotify::Plugin->compat) {
				Slim::Control::XMLBrowser::cliQuery($command, $wrapper || $feed, $request);
			} else {
				Slim76Compat::Control::XMLBrowser::cliQuery($command, $wrapper || $feed, $request);
			}
		};

		$client->block() if $showBlock;

		Plugins::Spotify::ContextMenuParser->get({}, { uri => $uri }, $contextCB, sub { $client->unblock() if $showBlock });
		return;

	} else {

		if ( $cachedFeed{ $cacheKey } ) {

			$log->info("using cached feed key: $cacheKey");

			my $feed = __PACKAGE__->menu(@{ $cachedFeed{ $cacheKey } });

			# wrap feed in another level if we have added the $sess value in the item_id
			my $wrapper = defined $sess ? sub {
				my ($client, $callback, $args) = @_;
				my $array = [];
				$array->[$sess] = $feed;
				$callback->($array);
			} : undef;

			# call xmlbrowser using compat version if necessary
			if (!Plugins::Spotify::Plugin->compat) {
				Slim::Control::XMLBrowser::cliQuery($command, $wrapper || $feed, $request);
			} else {
				Slim76Compat::Control::XMLBrowser::cliQuery($command, $wrapper || $feed, $request);
			}

			return;
		}
	}

	$log->warn("no feed");
	$request->setStatusBadParams();
}

1;
