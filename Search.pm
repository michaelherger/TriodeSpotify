package Plugins::Spotify::Search;

use strict;

use base qw(Plugins::Spotify::ParserBase);

use List::Util qw(max);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $log = logger("plugin.spotify");
my $prefs = preferences("plugin.spotify");

use constant MENU => \&Plugins::Spotify::Plugin::level;

sub request {
	my ($class, $args, $session) = @_;

	my $index    = $args->{'index'} || 0;
	my $quantity = $args->{'quantity'} || $prefs->get('maxsearch') || 500;
	my $search   = $args->{'search'} || $session->{'query'};

	$search = URI::Escape::uri_escape_utf8($search);

	$log->info("search: $search");

	# if diverting direct to match override paging params
	if ($session->{'exact'}) {
		$quantity = 1;
		$index = 0;
	}

	if ($session->{'top'}) {

		my $loc = $prefs->get('location') || 'user'; # 'user' indicates current user location

		return "toplist.json?q=$session->{top}&r=$loc";

	} elsif ($session->{'new'}) {

		$session->{'cachekey'} = [$index, $quantity, "new" ];
		return "search.json?o=$index&alq=$quantity&q=tag:new";

	} elsif ($session->{'artistsearch'}) {

		$session->{'cachekey'} = [$index, $quantity, $search ];
		return "search.json?o=$index&arq=$quantity&q=$search";

	} elsif ($session->{'albumsearch'}) {

		$session->{'cachekey'} = [$index, $quantity, $search ];
		return "search.json?o=$index&alq=$quantity&q=$search";

	} elsif ($session->{'tracksearch'}) {

		$session->{'cachekey'} = [$index, $quantity, $search ];
		return "search.json?o=$index&trq=$quantity&q=$search";

	} elsif ($session->{'search'}) {
		# ignore offset and paging params for initial search so browse path works when browsing into artists/albums/tracks
		return "search.json?o=0&arq=10&alq=10&trq=10&q=$search";
	}
}

tie my %cache, 'Tie::Cache::LRU', 10;

sub result {
	my ($class, $json, $args, $session, $slicestart) = @_;

	my @dym; my @albums; my @artists; my @tracks;

	$log->info("search: $json->{type} $json->{search}");

	# cache non single entries so xmlbrowser can browse into them without new request to helper
	if (!defined $slicestart && $session->{'cachekey'}) {
		my ($i, $q, $s) = @{$session->{'cachekey'}};
		if (!exists $cache{$s}) {
			tie my %c, 'Tie::Cache::LRU', 10;
			$cache{$s} = \%c;
		}
		$cache{$s}->{"$i:$q"} = $json;
	}

	if (!$session->{'exact'}) {
		
		# Did you mean...
		if ((my $dym = $json->{'did-you-mean'}) ne '') {
			
			$log->info("dym: $dym");
			
			my $dymname = ucfirst $dym;
			
			push @dym, {
				'name' => sprintf(string("PLUGIN_SPOTIFY_DID_YOU_MEAN"), $dymname),
				'url'  => MENU, 
				'type' => 'link',
				'passthrough' => [ 'Search', { %$session, query => $dym } ],
			};
		}
		
		# Top level search menu showing results for each search scope
		if ($session->{'search'} && !$session->{'artistsearch'} && !$session->{'albumsearch'} && !$session->{'tracksearch'}) {
			return {
				'items' => [ 
					@dym,
					{ name => "Artists (" . $json->{'total-artists'} . ")", 
					  url  => MENU, 
					  type => 'link',
					  passthrough => [ 'Search', { %$session, query => $args->{'search'} || $session->{'query'}, artistsearch => 1 } ], },
					{ name => "Albums (" . $json->{'total-albums'} . ")", 
					  url  => MENU, 
					  type => 'link',
					  passthrough => [ 'Search', { %$session, query => $args->{'search'} || $session->{'query'}, albumsearch => 1 } ], },
					{ name => "Tracks (" . $json->{'total-tracks'} . ")", 
					  url  => MENU, 
					  type => 'link',
					  passthrough => [ 'Search', { %$session, query => $args->{'search'} || $session->{'query'}, tracksearch => 1 } ], },
				   ]
			   };
		}

		# only update recent list when browsing into top level results otherwise we update the list while browsing into the recent menu
		if ($json->{'type'} eq 'search' && !$session->{'recent'}) {
			Plugins::Spotify::Recent->updateRecentSearches($args->{'search'} || $session->{'query'});
		}
	}

	for my $album (@{$json->{'albums'}}) {

		$log->debug("album: $album->{name} $album->{uri}");

		push @albums, {
			'name'     => $album->{'name'}. " " . string('BY') . " " . $album->{'artist'},
			'line1'    => $album->{'name'},
			'line2'    => $album->{'artist'},
			'url'      => MENU,
			'uri'      => $album->{'uri'},
			'image'    => Plugins::Spotify::Image->uri($album->{cover}),
			'type'     => 'playlist',
			'passthrough' => [ 'AlbumBrowse', { %$session, album => $album->{'uri'} } ],
			'play'     => $album->{'uri'},
			'hasMetadata' => 'album',
			'itemActions' => $class->actions({ info => 1, play => 1, uri => $album->{'uri'} }),
		};
	}
	
	for my $artist (@{$json->{'artists'}}) {

		my $name = $artist->{'name'};
		my $uri  = $artist->{'uri'};

		$log->debug("artist: $artist->{name} $artist->{uri}");

		push @artists, {
			'name'   => $artist->{'name'},
			'url'    => MENU,
			'uri'    => $artist->{'uri'},
			'type'   => $session->{'ipeng'} ? 'opml' :'playlist',
			'passthrough' => [ 'ArtistBrowse', { %$session, artist => $artist->{'uri'} } ],
			'itemActions' => $class->actions({ info => 1, play => 1, uri => $artist->{'uri'} }),
		};
	}

	for my $track (@{$json->{'tracks'}}) {

		my $artist = join(", ", map { $_->{'name'} } @{$track->{'artists'}});

		$log->debug("track: $track->{name} by $artist $track->{uri}");

		push @tracks, {
			'name'     => $track->{'name'} . " " . string('BY') . " " . $artist,
			'line1'    => $track->{'name'},
			'line2'    => $artist . " \x{2022} " . $track->{'album'},
			'url'      => $track->{'uri'},
			'uri'      => $track->{'uri'},
			'icon'     => Plugins::Spotify::Image->uri($track->{'cover'}),
			'type'     => 'audio',
			'itemActions' => $class->actions({ info => 1, play => 1, uri => $track->{'uri'} }),
		};
	}

	my $ret = [ @dym, @albums, @artists, @tracks ];

	if ($session->{'top'} && $session->{'top'} eq 'tracks' && scalar @tracks >= 2) {
		unshift @$ret, {
			name  => string('ALL_SONGS'),
			type  => 'audio',
			icon  => 'html/images/albums.png',
			itemActions => $class->actions({ play => 1, uri => 'toptracks' }),
		};
	}

	if (!scalar @$ret) {
		return $class->error('PLUGIN_SPOTIFY_NO_SEARCH_RESULTS');
	}

	my $total = max($json->{'total-artists'}, $json->{'total-albums'}, $json->{'total-tracks'});

	# restrict search menu length on non web interfaces
	if (!$session->{'isWeb'} && $total > $prefs->get('maxsearch')) {
		$total = $prefs->get('maxsearch');
	}

	# slice out single entry if using cached value
	if (defined $slicestart) {
		$ret = [ $ret->[ ($args->{'index'} || 0) - $slicestart ] ];
		$total = 1;
	}

	$log->debug("total: $total");

	return { 
		items  => $ret,
		offset => !$session->{'top'} ? ($args->{'index'} || 0) : undef,
		total  => $total,
	};
}

sub get {
	my ($class, $args, $session, $callback) = @_;

	# avoid asking helper for specific items as offset my be wrong
	if (!$session->{'exact'} && $args->{'quantity'} == 1) {
		$class->request($args, $session);
		if ($session->{'cachekey'} && $cache{ $session->{'cachekey'}->[2] }) {
			my ($i, $q, $s) = @{$session->{'cachekey'}};
			for my $k (keys %{$cache{$s}}) {
				my ($start, $quant) = split (":", $k);
				if ($i >= $start && $i < $start + $quant) {
					$log->info("slice hit, using cache: $i in $k $s");
					$callback->($class->result($cache{$s}->{$k}, $args, $session, $start));
					return;
				}
			}
		}
	}

	# attempt to go direct to the search result, missing menu level
	if ($session->{'exact'}) {

		my $cb = sub {
			my $search = shift;

			if (scalar @{$search->{'items'}} == 1 && (my $res = $search->{'items'}->[0])) {

				if ($res->{'url'} && ref $res->{'url'} eq 'CODE') {

					$log->info("going direct to search result");

					my @pt = @{ $res->{'passthrough'} || [] };
					delete $pt[1]->{'exact'};

					# we have no client, so pass undef as first arg
					$res->{'url'}->(undef, $callback, $args, @pt);

					return;
				}
			}
			# fallback to using this result
			$callback->($search);
		};

		$class->SUPER::get($args, $session, $cb);
		return;
	}

	$class->SUPER::get($args, $session, $callback);
}

1;
