package Plugins::Spotify::Radio;

use strict;

use JSON::XS::VersionOneAndTwo;
use XML::Simple;
use URI::Escape;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::Spotify::RadioProtocolHandler;

my $prefs = preferences('plugin.spotify');

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.spotify.radio',
	'defaultLevel' => 'WARN',
	'description'  => 'Spotify',
});

use constant PLAYLIST_MAXLENGTH => 10;

my @stopcommands = qw(clear loadtracks playtracks load play loadalbum playalbum);

my @genres = (
	# taken from http://news.spotify.com/uk/2009/03/24/spotify-genres-the-full-listing/
	# sorted by highest track count, only including genres with more than 1000 tracks - 319 genres
	"Pop/Rock", "Alternative Pop/Rock", "Jazz", "Latin", "Country", "Folk", "Traditional Pop", "Soul", "Hard Rock", 
	"Gospel", "Vocal", "Indie Rock", "Heavy Metal", "Electronic", "Club/Dance", "Soft Rock", "Hard Bop", 
	"Latin Pop", "Rap", "Blues", "Bop", "Adult Alternative Pop/Rock", "Album Rock", "Contemporary Folk", 
	"Traditional Country", "Adult Contemporary", "Urban", "New Wave", "New Age", "Vocal Jazz", "CCM", "Psychedelic", 
	"College Rock", "Modal Music", "Singer/Songwriter", "Progressive Country", "Post-Bop", "AM Pop", "Dance-Pop", 
	"Vocal Pop", "Contemporary Jazz", "Classical", "Easy Listening", "Indie Pop", "Hardcore Rap", "Alternative Metal", 
	"Standards", "Fusion", "Punk", "Folk-Rock", "Contemporary Country", "Electric Blues", "Reggae", "Swing", 
	"World Fusion", "Acoustic Blues", "Holiday", "Christmas", "Electric Texas Blues", "Electronica", "Country-Pop", 
	"Soundtracks", "Country-Rock", "Modern Electric Texas Blues", "Blues-Rock", "Post-Punk", "Techno", "Honky Tonk", 
	"Punk Revival", "Contemporary Instrumental", "Film Music", "French Pop", "Electric Chicago Blues", "Euro-Pop", 
	"Tropical", "Avant-Garde", "Cool", "Celtic", "Traditional Folk", "Contemporary Gospel", "American Punk", 
	"Gangsta Rap", "Big Band", "Dance-Rock", "Funk", "Crossover Jazz", "Texas Blues", "Free Jazz", "Post-Grunge", 
	"Arena Rock", "Punk-Pop", "Piano Blues", "East Coast Rap", "Experimental Rock", "British Invasion", "Hardcore Punk", 
	"Modern Electric Blues", "Electric Harmonica Blues", "Ambient", "Country Blues", "Urban Blues", "Comedy", 
	"Traditional Gospel", "Prewar Country Blues", "Italian Pop", "American Underground", "House", "Original Score", 
	"Soul-Jazz", "Pop-Soul", "Mainstream Jazz", "Jazz-Pop", "Cast Recordings", "Avant-Garde Jazz", "Christian Rock", 
	"Alternative CCM", "Latin Jazz", "Disco", "Tejano", "Rock en Español", "Afro-Cuban", "Show Tunes", "European Folk", 
	"Southern Rap", "British Folk", "Quiet Storm", "Neo-Psychedelia", "Bluegrass", "Experimental Techno", 
	"West Coast Rap", "Smooth Jazz", "Children's", "Rockabilly", "Synth Pop", "Underground Rap", "Pop-Metal", 
	"Emo", "Britpop", "Roots Reggae", "Smooth Soul", "Experimental", "Chicago Blues", "Contemporary Singer/Songwriter", 
	"Alternative Rap", "Dixieland", "Roots Rock", "Americana", "Instrumental Rock", "Alternative Country-Rock", 
	"Motown", "Salsa", "Dream Pop", "Black Gospel", "Alternative Dance", "Bolero", "Nashville Sound/Countrypolitan", 
	"Teen Pop", "Trip-Hop", "Ethnic Fusion", "Modern Creative", "Worldbeat", "British Punk", "Instrumental Pop", 
	"Industrial", "MPB", "Brazilian Pop", "Orchestral Pop", "Contemporary Reggae", "Indie Electronic", "Inspirational", 
	"Contemporary Celtic", "Ska Revival", "Blue-Eyed Soul", "Jazz-Funk", "Afro-Cuban Jazz", "Prewar Blues", 
	"Boogie Rock", "Neo-Traditionalist Country", "Folk-Blues", "West Coast Jazz", "French Rock", "Pop-Rap", 
	"Adult Alternative", "Hair Metal", "New Traditionalist", "Cabaret", "Spoken Word", "Dancehall", "British Folk-Rock", 
	"Sweet Bands", "Dirty South", "Dub", "Jump Blues", "Post-Hardcore", "Euro-Dance", "American Trad Rock", 
	"Blues Revival", "Proto-Punk", "Contemporary Blues", "Southern Rock", "Progressive Metal", "Sunshine Pop", 
	"Country-Folk", "New Orleans Jazz", "Flamenco", "Goth Rock", "Bossa Nova", "Power Pop", "Ambient Techno", 
	"Norteño", "Progressive Bluegrass", "Third Wave Ska Revival", "Jazz Blues", "Soul-Blues", "Trance", 
	"Progressive Jazz", "Classical Crossover", "Reggae-Pop", "Delta Blues", "Brazilian Jazz", "Lo-Fi", "Jazz-Rock", 
	"Torch Songs", "Garage Rock Revival", "American Popular Song", "Asian Folk", "Baroque Pop", "Southern Soul", 
	"Classic Female Blues", "Ranchera", "Traditional Bluegrass", "Latin Rap", "Samba", "Psychedelic Pop", 
	"Folksongs", "Slide Guitar Blues", "IDM", "Rockabilly Revival", "Early American Blues", "Outlaw Country", 
	"Glam Rock", "Chamber Pop", "Standup Comedy", "Easy Pop", "Neo-Soul", "British Blues", "Brill Building Pop", 
	"Lounge", "Irish Folk", "Folk-Pop", "Pop", "Traditional European Folk", "New Romantic", "Early British Pop/Rock", 
	"Ska-Punk", "Garage Punk", "Political Folk", "Neo-Classical", "Jungle/Drum'n'bass", "Industrial Metal", 
	"Rap-Metal", "Noise-Rock", "Alternative Singer/Songwriter", "British Metal", "Urban Cowboy", "Southern Gospel", 
	"Political Reggae", "Tango", "Progressive Electronic", "Afro-Pop", "Jam Bands", "Western Swing", "Tex-Mex", 
	"Guitar Virtuoso", "Folk Revival", "New York Punk", "New Wave/Post-Punk Revival", "Grindcore", "Piedmont Blues", 
	"Celtic Folk", "Alternative Folk", "Solo Instrumental", "Jangle Pop", "Cowboy", "British Trad Rock", 
	"Scandinavian Metal", "Country Gospel", "Cuban Jazz", "British Psychedelia", "Harmonica Blues", "Opera", 
	"Ragga", "Speed Metal", "Noise Pop", "Stride", "Novelty", "Heartland Rock", "Surf", "Punk Metal", "Grunge", 
	"Comedy Rock", "Acid Jazz", "Ska", "Children's Folk", "Deep Soul", "Space Rock", "Contemporary Bluegrass", 
	"Golden Age", "Detroit Rock", "Philly Soul", "Funk Metal", "Modern Composition", "Mariachi", "Progressive Folk", 
	"Industrial Dance", "Goth Metal", "Mambo", "Chamber Jazz", "Indian Classical",
);

sub init {
	Slim::Control::Request::addDispatch(['spotifyradio', '_type'], [1, 0, 0, \&cliRequest]);

	Slim::Control::Request::subscribe(\&commandCallback, [['playlist'], ['newsong', 'delete', @stopcommands]]);
}

sub level {
	my ($client, $callback, $args, $session) = @_;

	$session ||= {};
	my @menu;
	my @topGenres = @genres[ 0 .. $prefs->get('radio_genres') ];

	for my $genre (sort @topGenres) {
		push @menu, {
			name => $genre,
			type => 'audio',
			url  => "spotifyradio:genre:" . '"' . $genre . '"',
		};
	}
	
	$callback->(\@menu);
}

sub cliRequest {
	my $request = shift;
 
	my $client = $request->client;
	my $type = $request->getParam('_type'); 

	if (Slim::Player::Playlist::shuffle($client)) {

		if ($client->can('inhibitShuffle')) {
			$client->inhibitShuffle('spotifyradio');
		} else {
			$log->warn("WARNING: turning off shuffle mode");
			Slim::Player::Playlist::shuffle($client, 0);
		}
	}

	if ($type eq 'genre') {
		
		my $genre = $request->getParam('_p2');

		$log->info("spotify radio genre mode, genre: $genre");

		_playRadio($client, { genre => $genre });

	} elsif ($type eq 'artist') {
		
		my $artist = $request->getParam('_p2');

		$log->info("spotify radio artist mode, artist: $artist");

		_playRadio($client, { artist => $artist, rand => 1 });

	} elsif ($type eq 'similar') {
		
		my $artist = $request->getParam('_p2');

		$log->info("spotify radio similar artist mode, artist: $artist");

		_playRadio($client, { similar => $artist, rand => 1 });

	} elsif ($type eq 'playlist') {
		
		my $playlist = $request->getParam('_p2');

		$log->info("spotify radio playlist mode, artist: $playlist");

		_playRadio($client, { playlist => $playlist });

	} elsif ($type eq 'lastfmrec') {

		my $user = $request->getParam('_p2');
		
		$log->info("spotify radio playlist mode, lastfm recommended: $user");

		_playRadio($client, { lastfmrec => $user, rand => 1 });

	} elsif ($type eq 'lastfmsimilar') {

		my $similar = $request->getParam('_p2');
		
		$log->info("spotify radio playlist mode, lastfm similar artist: $similar");

		_playRadio($client, { lastfmsimilar => $similar, rand => 1 });
	}

	$request->setStatusDone();
}

sub _playRadio {
	my $master = shift->master;
	my $args   = shift;
	my $callback = shift;

	if ($args) {
		$master->pluginData('running', 1);
		$master->pluginData('args', $args);
		$master->pluginData('tracks', []);
	} else {
		$args = $master->pluginData('args');
	}

	return unless $master->pluginData('running');

	my $tracks = $master->pluginData('tracks');
	
	my $load = ($master->pluginData('running') == 1);

	my $tracksToAdd = $load ? PLAYLIST_MAXLENGTH : PLAYLIST_MAXLENGTH - scalar @{Slim::Player::Playlist::playList($master)};

	# for similar artists only add one track per artist per call until all artists lists have been fetched
	if ($tracksToAdd && ($args->{'similar'} || $args->{'lastfmrec'} || $args->{'lastfmsimilar'}) && !$args->{'allfetched'}) {
		$tracksToAdd = 1;
	}

	if ($tracksToAdd) {

		my @tracksToAdd;

		while ($tracksToAdd && scalar @$tracks) {

			my ($index, $entry);

			if ($args->{'rand'}) {

				# pick a random track, attempting to avoid one with the same title as last track
				# if called from a callback then pick from within the topmost $callback tracks ie from the most recent fetch
				# ensure the range of indexes considered shrinks as $tracks shrink so we always pick a track from the list
				my $consider = $callback || scalar @$tracks;
				if ($consider > scalar @$tracks) {
					$consider = scalar @$tracks;
				}

				my $tries = 3;
				do {

					$index = -int(rand($consider));

				} while ($tracks->[$index]->{'name'} ne ($master->pluginData('lasttitle') || '') && $tries--);

				$master->pluginData('lasttitle', $tracks->[$index]->{'name'});

			} else {

				# take first track
				$index = 0;
			}

			$entry = splice @$tracks, $index, 1;

			# create remote track obj late to ensure it stays in the S:S:RemoteTrack LRU
			my $obj = Slim::Schema::RemoteTrack->updateOrCreate($entry->{'uri'}, {
				title   => $entry->{'name'},
				artist  => join(", ", map { $_->{'name'} } @{$entry->{'artists'}}),
				album   => $entry->{'album'},
				secs    => $entry->{'duration'} / 1000,
				cover   => $entry->{'cover'},
				tracknum=> $entry->{'index'},
			});

			if ($obj) {
				$obj->stash->{'starred'} = $entry->{'starred'};
				push @tracksToAdd, $obj;
			}

			$tracksToAdd--;
		}

		if (@tracksToAdd) {

			$log->info(($load ? "loading " : "adding ") . scalar @tracksToAdd . " tracks, pending tracks: " . scalar @$tracks);
			
			$master->execute(['playlist', $load ? 'loadtracks' : 'addtracks', 'listRef', \@tracksToAdd])->source('spotifyradio');

			if ($load) {
				$master->pluginData('running', 2);
			}
		}
	}

	if ($tracksToAdd > 0 && !$callback) {

		if ($args->{'genre'}) {

			$log->info("fetching radio tracks from spotifyd");

			fetchGenreTracks($master, $tracks, $args);

		} elsif ($args->{'artist'}) {

			$log->info("fetching artist tracks from spotifyd");

			fetchArtistTracks($master, $tracks, $args);

		} elsif ($args->{'similar'}) {

			$log->info("fetching similar artist tracks from spotifyd");

			fetchSimilarTracks($master, $tracks, $args);

		} elsif ($args->{'playlist'}) {

			$log->info("fetching playlist tracks from spotifyd");

			fetchPlaylistTracks($master, $tracks, $args);

		} elsif ($args->{'lastfmrec'}) {

			$log->info("fetching recommendation from lastfm");

			fetchLastfmTracks($master, $tracks, $args);

		} elsif ($args->{'lastfmsimilar'}) {

			$log->info("fetching similar artists from lastfm");

			fetchLastfmTracks($master, $tracks, $args);
		}
	}
}

sub fetchGenreTracks {
	my ($master, $tracks, $args) = @_;

	my $genre = Slim::Utils::Misc::escape($args->{'genre'});

	my $cb = sub {

		my $count = 20; # fetch this many tracks

		if ($args->{'total-tracks'}) {

			while (--$count) {

				my $rand; my $try = 10;
				
				do {
					
					$rand = int(rand(scalar $args->{'total-tracks'}));
					
				} while ($args->{'picked'}->{ $rand } && $try--);
				
				$args->{'picked'}->{ $rand } = 1;
				
				# ask for 3 tracks to maximise chance of getting a playable track, _fetchTracks will use the first one
				my $url = Plugins::Spotify::Spotifyd->uri("search.json?o=$rand&trq=3&q=genre:$genre");
				
				_fetchTracks($master, $tracks, $args, $url);
			}
		}
	};

	if ($args->{'total-tracks'}) {

		$cb->();

	} else {

		Slim::Networking::SimpleAsyncHTTP->new(
			
			sub {
				my $http = shift;
				
				my $json = eval { from_json($http->content) };
				
				if ($@) {
					$log->warn($@);
				}
				
				if ($json->{'total-tracks'}) {
					$args->{'total-tracks'} = $json->{'total-tracks'};
					$args->{'picked'} = {};
					$cb->();
				}
			},
					
			sub {
				$log->warn("error fetching genre first track from spotifyd");
			},
			
			{ timeout => 35 },
			
		)->get( Plugins::Spotify::Spotifyd->uri("search.json?o=0&trq=3&q=genre:$genre") );
	}
}

sub fetchArtistTracks {
	my ($master, $tracks, $args) = @_;

	my $url = Plugins::Spotify::Spotifyd->uri("$args->{artist}/tracks.json");

	_fetchTracks($master, $tracks, $args, $url);
}

sub fetchSimilarTracks {
	my ($master, $tracks, $args) = @_;

	my $artisturl  = Plugins::Spotify::Spotifyd->uri("$args->{similar}/randtracks.json");
	my $similarurl = Plugins::Spotify::Spotifyd->uri("$args->{similar}/browse.json");

	$log->info("fetching similar artists from spotifyd: $similarurl");
	
	my @urls;

	Slim::Networking::SimpleAsyncHTTP->new(
			
		sub {
			my $http = shift;
			
			if ($master->pluginData('args') != $args) {
				$log->info("ignoring response radio session not current");
				return;
			}

			my $json = eval { from_json($http->content) };

			if ($@) {
				$log->warn($@);
			}

			my $artistCount = scalar @{ $json->{'similarartists'} || [] };

			$log->info("found $artistCount artists");

			my $max = $artistCount > 20 ? 20 : 100;

			push @urls, "$artisturl?max=$max";
			
			for my $similar (@{$json->{'similarartists'} || []}) {

				my $url = Plugins::Spotify::Spotifyd->uri("$similar->{artisturi}/randtracks.json?max=$max");

				push @urls, $url;
			}

			my $cb;

			$cb = sub {
				my $url = shift @urls;

				if (!$url) {
					$args->{'allfetched'} = 1;
					return;
				}

				_fetchTracks($master, $tracks, $args, $url, $cb);
			};

			$cb->();
		}, 
			
		sub {
			$log->warn("error fetching similar artists from spotifyd");
		},
			
		{ timeout => 35 },
			
	)->get($similarurl);
}

sub fetchPlaylistTracks {
	my ($master, $tracks, $args) = @_;

	my $url = Plugins::Spotify::Spotifyd->uri("$args->{playlist}/playlists.json");

	_fetchTracks($master, $tracks, $args, $url);
}

sub fetchLastfmTracks {
	my ($master, $tracks, $args) = @_;

	my $lastfmurl;

	my @artists;

	if (my $user = $args->{'lastfmrec'}) {

		$log->info("fetching recommended artists from lastfm for user: $user");

		$lastfmurl = "http://ws.audioscrobbler.com/1.0/user/" . URI::Escape::uri_escape_utf8($user) . "/systemrecs.xml";

	} elsif (my $artist = $args->{'lastfmsimilar'}) {

		$log->info("fetching similar artists from lastfm for arist: $artist");

		push @artists, $artist;

		$lastfmurl = "http://ws.audioscrobbler.com/1.0/artist/" . URI::Escape::uri_escape_utf8($artist) . "/similar.xml";

	} else {
		$log->warn("bad args");
	}
	
	Slim::Networking::SimpleAsyncHTTP->new(
			
		sub {
			my $http = shift;
			
			if ($master->pluginData('args') != $args) {
				$log->info("ignoring response radio session not current");
				return;
			}

			my $xml = eval { XMLin($http->content) };

			if ($@) {
				$log->warn($@);
			}

			if ($args->{'lastfmrec'}) {

				@artists = keys %{$xml->{'artist'}};

			} else {
				for my $entry (@{$xml->{'artist'}}) {
					if (ref $entry eq 'HASH') { 
						push @artists, $entry->{'name'};
					}
				}
			}

			$log->info("found " . scalar @artists . " artists");

			my $max = scalar @artists > 20 ? 20 : 100;

			my $cb;

			$cb = sub {

				if (!scalar @artists) {
					$args->{'allfetched'} = 1;
					return;
				}

				if ($master->pluginData('args') != $args) {
					$log->info("ignoring response radio session not current");
					return;
				}

				my $artist = $args->{'lastfmrec'} ? splice @artists, int(rand(scalar @artists)), 1 : shift @artists;

				$log->info("looking up artist: $artist");
				
				Slim::Networking::SimpleAsyncHTTP->new(
					
					sub {
						my $http = shift;
						
						my $json = eval { from_json($http->content) };
						
						if ($@) {
							$log->warn($@);
						}
						
						# assume direct match is always first entry
						if ($json->{'artists'} && scalar $json->{'artists'} >= 1 && $json->{'artists'}->[0]->{'name'} eq $artist) {
							
							my $artisturi = $json->{'artists'}->[0]->{'uri'};
							
							my $url = Plugins::Spotify::Spotifyd->uri("$artisturi/randtracks.json?max=$max");

							_fetchTracks($master, $tracks, $args, $url, $cb);

						} else {
							$log->info("artist not found: $artist");
							$cb->();
						}
					}, 
					
					sub {
						$log->warn("error searching for artist: $artist");
						$cb->();
					},
					
					{ timeout => 15 }
						
				)->get( Plugins::Spotify::Spotifyd->uri("search.json?o=0&arq=1&q=artist:") . URI::Escape::uri_escape_utf8($artist) );
			};

			$cb->();

		}, 
			
		sub {
			$log->warn("error fetching recommened artists from lastfm");
		},
			
		{ timeout => 15 },
			
	)->get($lastfmurl);
}

sub _fetchTracks {
	my ($master, $tracks, $args, $url, $cb) = @_;

	$log->info("fetching tracks from spotifyd: $url");

	Slim::Networking::SimpleAsyncHTTP->new(
			
		sub {
			my $http = shift;
			
			if ($master->pluginData('args') != $args) {
				$log->info("ignoring response radio session not current");
				return;
			}

			my $json = eval { from_json($http->content) };

			if ($@) {
				$log->warn($@);
			}

			if ($args->{'genre'}) {
				# only use first track for genre requests
				$json->{'tracks'} = [ $json->{'tracks'}->[0] ];
			}
			
			push @$tracks, @{$json->{'tracks'} || []};

			my $newtracks = scalar @{$json->{'tracks'} || []};

			$log->info(sub{ sprintf("got %d tracks, pending tracks now %s", $newtracks, scalar @$tracks) });
			
			_playRadio($master, undef, $newtracks) if $newtracks;

			$cb->() if $cb;
		}, 
			
		sub {
			$log->warn("error fetching radio tracks from spotifyd");
			$cb->() if $cb;
		},
			
		{ timeout => 35 },
			
	)->get($url);
}

sub playingRadioStream {
	my $client = shift;
	return $client->master->pluginData('running');
}

sub commandCallback {
	my $request = shift;
	my $client  = $request->client;
	my $master  = $client->master;

	$log->is_debug && $log->debug(sprintf("[%s] %s source: %s", $request->getRequestString, 
		Slim::Player::Sync::isMaster($client) ? 'master' : 'slave',	$request->source || ''));

	return if $request->source && $request->source eq 'spotifyradio';

	return if $request->isCommand([['playlist'], ['play', 'load']]) && $request->getParam('_item') =~ "^spotifyradio:";

	if ($master->pluginData('running')) {

		my $songIndex = Slim::Player::Source::streamingSongIndex($master);
		
		if ($request->isCommand([['playlist'], [@stopcommands]])) {
			
			$log->info("stopping radio");
			
			$master->pluginData('running', 0);
			$master->pluginData('tracks', []);
			$master->pluginData('args', {});
			
			if ($master->can('inhibitShuffle') && $master->inhibitShuffle && $master->inhibitShuffle eq 'spotifyradio') {
				$master->inhibitShuffle(undef);
			}
			
		} elsif ($request->isCommand([['playlist'], ['newsong']] ||
				 ($request->isCommand([['playlist'], ['delete']]) && $request->getParam('_index') > $songIndex)
				)) {
				
			$log->info("playlist changed - checking whether to add or remove tracks");
			
			if ($songIndex && $songIndex >= int(PLAYLIST_MAXLENGTH / 2)) {
				
				my $remove = $songIndex - int(PLAYLIST_MAXLENGTH / 2) + 1;
				
				$log->info("removing $remove track(s) songIndex: $songIndex");
				
				while ($remove--) {
					$master->execute(['playlist', 'delete', 0])->source('spotifyradio');
				}
			}
			
			_playRadio($master);
		}
	}
}

1;
