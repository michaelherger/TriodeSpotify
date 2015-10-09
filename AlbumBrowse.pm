package Plugins::Spotify::AlbumBrowse;

use strict;

use base qw(Plugins::Spotify::ParserBase);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

my $log = logger("plugin.spotify");

use constant MENU => \&Plugins::Spotify::Plugin::level;

sub request {
	my ($class, $args, $session) = @_;
	return "$session->{album}/browse.json";
}

sub result {
	my ($class, $json, $args, $session) = @_;

	$log->info("browse album: $json->{album} by $json->{artist} $json->{uri}");

	if (defined $json->{'avail'} && !$json->{'avail'}) {
		return $class->error('PLUGIN_SPOTIFY_ALBUM_NOT_AVAILABLE');
	}

	# update recently browsed artists & albums
	Plugins::Spotify::Recent->updateRecentArtists($json->{'artist'}, $json->{'artisturi'}); 
	Plugins::Spotify::Recent->updateRecentAlbums($json->{'artist'}, $json->{'album'}, $json->{'uri'}, $json->{'cover'});

	my @menu;
	my $i = 0;

	my $icon = Plugins::Spotify::Image->uri($json->{cover});

	for my $entry (@{$json->{'tracks'}}) {

		$log->info("track: $entry->{name} $entry->{uri}");

		my $artist = join(", ", map { $_->{'name'} } @{$entry->{'artists'}});

		push @menu, {
			'name'     => $entry->{'name'},
			'line1'    => $entry->{'name'},
			'line2'    => $artist . " \x{2022} " . $json->{'album'},
			'url'      => $entry->{'uri'},
			'icon'     => $icon,
			'duration' => $entry->{'duration'},
			'type'     => 'audio',
			'_disc'    => $entry->{'disc'},
			'_track'   => $entry->{'index'},
			'itemActions' => $class->actions({ info => 1, play => 1, uri => $entry->{'uri'},
											   playuri => $session->{'playalbum'} ? $json->{'uri'} : $entry->{'uri'},
											   ind => $session->{'playalbum'} ? $i : undef }),
		};
		
		$i++;
	}

	@menu = sort { $a->{_disc} != $b->{_disc} ? $a->{_disc} <=> $b->{_disc} : $a->{_track} <=> $b->{_track} } @menu;

	my $ret = {
		name  => $json->{'album'},
		cover => $icon,
		items => \@menu,
	};

	if ($args->{'wantMetadata'}) {
		$ret->{'albumInfo'} = { info => { command => [ 'spotifyinfocmd', 'items' ], fixedParams => { uri => $json->{'uri'} } } },
		$ret->{'albumData'} = [
			{ type => 'link', label => 'ARTIST', name => $json->{'artist'}, url => 'anyurl',
			  itemActions => $class->actions({ items => 1, uri => $json->{'artisturi'} }),
		  },
			{ type => 'link', label => 'ALBUM', name => $json->{'album'} },
			{ type => 'link', label => 'YEAR', name => $json->{'year'} },
		];
	};

	return $ret;
}

1;
