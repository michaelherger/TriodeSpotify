package Plugins::Spotify::ArtistBrowse;

use strict;

use base qw(Plugins::Spotify::ParserBase);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $prefs = preferences("plugin.spotify");
my $log = logger("plugin.spotify");

use constant MENU => \&Plugins::Spotify::Plugin::level;

sub request {
	my ($class, $args, $session) = @_;
	return "$session->{artist}/browse.json";
}

sub result {
	my ($class, $json, $args, $session) = @_;

	$log->info("browse artist: $json->{artist} $json->{artisturi}");

	# update recently browsed artists
	Plugins::Spotify::Recent->updateRecentArtists($json->{'artist'}, $json->{'artisturi'});

	my $artistimage;

	if (scalar @{$json->{'artistimages'}} >= 1) {
		$artistimage = Plugins::Spotify::Image->uri($json->{'artistimages'}->[0]);
	}

	my $types = {};

	for my $album (@{$json->{'albums'}}) {

		my $name      = $album->{'name'};
		my $yr        = $album->{'year'};
		my $uri       = $album->{'uri'};
		my $type      = $album->{'type'};
		my $cover     = $album->{'cover'};

		$log->debug("album: $name $uri $yr $type");

		push @{$types->{lc $type}}, {
			'name'     => "$name ($yr)",
			'type'     => 'playlist',
			'url'      => MENU,
			'image'    => Plugins::Spotify::Image->uri($cover),
			'_yr'      => $yr,
			'passthrough' => [ 'AlbumBrowse', { %$session, album => $uri } ],
			'itemActions' => $class->actions({ info => 1, play => 1, uri => $uri }),
			'play'        => $uri,
			'hasMetadata' => 'album',
		};
	}

	for my $type (keys %$types) {
		@{$types->{$type}} = sort { $a->{_yr} == $b->{_yr} ? $a->{name} cmp $a->{name} : $b->{_yr} <=> $a->{_yr} } @{$types->{$type}};
	}

	my @menu;

	push @menu, {
		'name'   => string('PLUGIN_SPOTIFY_ARTSIST_TOP_TRACKS'),
		'url'    => MENU,
		'passthrough' => [ 'TopTracks', { %$session, artist => $json->{'artisturi'}, top => 10, cover => $artistimage } ],
		'itemActions' => $class->actions({ play => 1, uri => $json->{'artisturi'}, top => 10 }),
		'type'   => 'playlist',
	};

	for my $type (qw(album single compilation other appears_on)) {
		if ($types->{$type}) {
			push @menu, {
				'name' => string('PLUGIN_SPOTIFY_ALBUM_' . uc $type) . " (" .scalar @{$types->{$type}} . ")",
				'items'=> $types->{$type},
				'type' => 'link',
				'cover' => $artistimage,
			};
		}
	}

	if ($prefs->get('lastfm')) {

		push @menu, {
			'name'   => string('PLUGIN_SPOTIFY_SIMILAR_ARTISTS'),
			'url'    => MENU,
			'passthrough' => [ 'LastFM', { $class->newSession($session), artist => $json->{'artist'} } ],
			'type'   => 'link',
		};

	} else {

		my @similar;

		for my $similar (@{$json->{'similarartists'}}) {
			push @similar, {
				'name' => $similar->{'name'},
				'type' => 'link',
				'url'  => MENU,
				'passthrough' => [ 'ArtistBrowse', { $class->newSession($session), artist => $similar->{'artisturi'} } ],
			};
		}
		
		push @menu, {
			'name' => string('PLUGIN_SPOTIFY_SIMILAR_ARTISTS'),
			'items'=> \@similar,
			'type' => 'opml',
		};
	}

	if ($json->{'artistimages'} && scalar @{$json->{'artistimages'}}) {

		my @images;

		for my $image (@{$json->{'artistimages'}}) {
			push @images, {
				'name' => $json->{'artist'},
				'image'=> Plugins::Spotify::Image->uri($image),
				'type' => 'slideshow',
				'date' => '',
				'owner'=> '',
			};
		}

		push @menu, {
			'name' => string('PLUGIN_SPOTIFY_ARTIST_IMAGES'),
			'type' => 'slideshow',
			'items'=> \@images,
		};
	}

	push @menu, {
		'name'   => string('PLUGIN_SPOTIFY_BIOGRAPHY'),
		'type'   => 'link',
		'url'    => MENU,
		'uri'    => $json->{'artisturi'},
		'passthrough' => [ 'Biography', { %$session, artist => $json->{'artist'}, artisturi => $json->{'artisturi'} } ],
	};

	push @menu, {
		'name' => string('PLUGIN_SPOTIFY_ARTIST_MIX') . $json->{'artist'},
		'type' => 'audio',
		'itemActions' => { play => { command => ['spotifyradio', 'artist', $json->{'artisturi'} ], },
						   allAvailableActionsDefined => 1,
						  },

	};

	if ($prefs->get('lastfm')) {

		push @menu, {
			'name' => string('PLUGIN_SPOTIFY_SIMILAR_ARTISTS_MIX') . $json->{'artist'},
			'type' => 'audio',
			'itemActions' => { play => { command => ['spotifyradio', 'lastfmsimilar', $json->{'artist'} ], },
							   allAvailableActionsDefined => 1,
						   },
		};

	} else {

		push @menu, {
			'name' => string('PLUGIN_SPOTIFY_SIMILAR_ARTISTS_MIX') . $json->{'artist'},
			'type' => 'audio',
			'itemActions' => { play => { command => ['spotifyradio', 'similar', $json->{'artisturi'} ], },
							   allAvailableActionsDefined => 1,
						   },
		};
	}

	return {
		items => \@menu,
		cover => $artistimage,
	};
}

1;
