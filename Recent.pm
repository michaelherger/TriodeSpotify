package Plugins::Spotify::Recent;

use strict;

tie my %recentArtists, 'Tie::Cache::LRU', 50;
tie my %recentAlbums, 'Tie::Cache::LRU', 50;
tie my %recentSearches, 'Tie::Cache::LRU', 20;
tie my %recentPlaylists, 'Tie::Cache::LRU', 20;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use constant MENU => \&Plugins::Spotify::Plugin::level;

my $prefs = preferences('plugin.spotify');
my $log   = logger('plugin.spotify');

$prefs->init({ recentartists => [], recentalbums => [], recentsearches => [], recentplaylists => [] });

# keep a cache of responses so we maintain the order as we decend into browse trees including recent entries
my %browseCache;

sub level {
	my ($client, $callback, $args, $type) = @_;

	my @menu;
	my $hash;

	if (defined $args->{'quantity'} && $args->{'quantity'} == 1 && $type ne 'searches') {
		$log->info("returning cached $type index $args->{index}");
		$callback->($browseCache{ $type });
		return;
	}

	$log->info("recent: $type");

	if ($type eq 'artists') {
		$hash = \%recentArtists;
	}

	if ($type eq 'albums') {
		$hash = \%recentAlbums;
	}

	if ($type eq 'searches') {
		$hash = \%recentSearches;
	}

	# do in reverse to maintain LRU order
	for my $uri (reverse keys %{$hash}) {

		my $entry = {
			'name' => $hash->{$uri}->{'name'},
			'url'  => MENU,
		};

		if ($type eq 'artists') {
			$entry->{'passthrough'} = [ 'ArtistBrowse', { artist => $uri } ];
			$entry->{'itemActions'} = Plugins::Spotify::ParserBase->actions({ info => 1, play => 1, uri => $uri });
		}

		if ($type eq 'albums') {
			if ($hash->{$uri}->{'artist'} && $hash->{$uri}->{'album'}) {
				$entry->{'name'}  = $hash->{$uri}->{'album'} . " " . string('BY') . " " . $hash->{$uri}->{'artist'};
				$entry->{'line1'} = $hash->{$uri}->{'album'};
				$entry->{'line2'} = $hash->{$uri}->{'artist'}
			};
			$entry->{'passthrough'} = [ 'AlbumBrowse', { album => $uri } ];
			$entry->{'play'} = $uri;
			$entry->{'hasMetadata'} = 'album';
			$entry->{'itemActions'} = Plugins::Spotify::ParserBase->actions({ info => 1, play => 1, uri => $uri });
		}

		if ($type eq 'searches') {
			$entry->{'passthrough'} = [ 'Search', { query => $uri, search => 1, recent => 1 } ];
		}

		$entry->{'image'} = Plugins::Spotify::Image->uri($hash->{$uri}->{'cover'}) if exists $hash->{$uri}->{'cover'};

		unshift @menu, $entry;
	}

	$browseCache{ $type } = \@menu;

	$callback->(\@menu);
}

sub load {
	my $class = shift;

	# read in reverse to maintain LRU order
	for my $artist (reverse @{$prefs->get('recentartists')}) {
		$recentArtists{ $artist->{'uri'} } = { name => $artist->{'name'} };
	}

	for my $album (reverse @{$prefs->get('recentalbums')}) {
		$recentAlbums{ $album->{'uri'} } = { artist => $album->{'artist'}, album => $album->{'album'}, cover => $album->{'cover'} };
		$recentAlbums{ $album->{'uri'} }->{'name'} = $album->{'name'} if $album->{'name'};
	}

	for my $search (reverse @{$prefs->get('recentsearches')}) {
		$recentSearches{ $search } = { name => $search };
	}

	for my $playlist (reverse @{$prefs->get('recentplaylists')}) {
		$recentPlaylists{ $playlist->{'uri'} } = { name => $playlist->{'name'} };
	}
}

sub save {
	my $class = shift;
	my $savenow = shift;

	if (!$savenow) {
		Slim::Utils::Timers::killTimers($class, \&save);
		Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 10, \&save, 'now');
		return;
	}

	my @artists;
	my @albums;
	my @searches;
	my @playlists;

	# read in reverse to maintain LRU order
	for my $uri (reverse keys %recentArtists) {
		unshift @artists, { name => $recentArtists{ $uri }->{'name'}, uri => $uri };
	}

	for my $uri (reverse keys %recentAlbums) {
		my $entry = { uri => $uri, cover => $recentAlbums{ $uri }->{'cover'},
					  artist => $recentAlbums{ $uri }->{'artist'}, album => $recentAlbums{ $uri }->{'album'} };
		$entry->{'name'} = $recentAlbums{ $uri }->{'name'} if $recentAlbums{ $uri }->{'name'}; 
	    unshift @albums, $entry;
	}
	
	for my $name (reverse keys %recentSearches) {
		unshift @searches, $name;
	}

	for my $uri (reverse keys %recentPlaylists) {
		unshift @playlists, { name => $recentPlaylists{ $uri }->{'name'}, uri => $uri };
	}

	$log->info("updating recent prefs");

	$prefs->set('recentartists', \@artists);
	$prefs->set('recentalbums', \@albums);
	$prefs->set('recentsearches', \@searches);
	$prefs->set('recentplaylists', \@playlists);
}

sub updateRecentArtists {
	my ($class, $name, $uri) = @_;

	$log->info("recent artist: $name -> $uri");

	$recentArtists{ $uri } = { name => $name };

	$class->save;
}

sub updateRecentAlbums {
	my ($class, $artist, $album, $uri, $cover) = @_;

	$log->info("recent album: $artist, $album -> $uri, $cover");

	$recentAlbums{ $uri } = { artist => $artist, album => $album, cover => $cover };

	$class->save;
}

sub updateRecentSearches {
	my ($class, $name) = @_;

	$log->info("recent search: $name");

	$recentSearches{ $name } = { name => $name };

	$class->save;
}

sub updateRecentPlaylists {
	my ($class, $name, $uri) = @_;

	$log->info("recent playlist: $name -> $uri");

	$recentPlaylists{ $uri } = { name => $name };

	$class->save;
}

sub removeRecentPlaylists {
	my ($class, $uri) = @_;

	$log->info("removing recent playlist: $uri");

	delete $recentPlaylists{ $uri };
}

sub recentPlaylists {
	my $class = shift;
	my $session = shift;

	my @menu;

	for my $uri (reverse keys %recentPlaylists) {
		unshift @menu, {
			'name'        => $recentPlaylists{$uri}->{'name'},
			'url'         => MENU,
			'uri'         => $uri,
			'passthrough' => [ 'SinglePlaylist', { %$session, uri => $uri, recent => 1 } ],
			'type'        => 'playlist',
			'itemActions' => Plugins::Spotify::ParserBase->actions({ info => 1, play => 1, uri => $uri }),
		};
	}

	return \@menu;
}

1;
