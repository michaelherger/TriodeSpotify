package Plugins::Spotify::Library;

use strict;

use JSON::XS::VersionOneAndTwo;
use File::Slurp;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use constant MENU => \&Plugins::Spotify::Plugin::level;

my $prefs = preferences('plugin.spotify');
my $log   = logger('plugin.spotify');

$prefs->init({ libraryartists => [], libraryalbums => [], librarytracks => [] });

my %uris;

sub level {
	my ($client, $callback, $args, $type) = @_;

	my @menu;

	$log->info("library: $type");

	my $ipeng = $args->{'params'}->{'userInterfaceIdiom'} && $args->{'params'}->{'userInterfaceIdiom'} =~ /iPeng/;

	for my $item (@{ $prefs->get("library$type") || [] }) {

		my $entry = {
			'name' => $item->{'name'},
			'url'  => MENU,
			'type' => $ipeng ? 'opml' : 'playlist',
			'itemActions' => Plugins::Spotify::ParserBase->actions({ info => 1, play => 1, uri => $item->{'uri'} }),
		};

		if ($type eq 'artists') {
			$entry->{'passthrough'} = [ 'ArtistBrowse', { artist => $item->{'uri'} } ];
		}

		if ($type eq 'albums') {
			$entry->{'passthrough'} = [ 'AlbumBrowse', { album => $item->{'uri'} } ];
			$entry->{'play'} = $item->{'uri'};
			$entry->{'hasMetadata'} = 'album';
		}

		if ($type eq 'tracks') {
			$entry->{'type'} = 'audio';
		}

		if ($item->{'name'} && $item->{'artist'}) {
			$entry->{'name'}  = $item->{'name'} . " " . string('BY') . " " . $item->{'artist'};
			$entry->{'line1'} = $item->{'name'};
			$entry->{'line2'} = $item->{'artist'}
		};

		$entry->{'image'} = Plugins::Spotify::Image->uri($item->{'cover'}) if exists $item->{'cover'};

		push @menu, $entry;
	}

	$callback->(\@menu);
}

sub init {
	map { $uris{ $_->{'uri'} } = 1 } @{ $prefs->get('libraryartists') || [] };
	map { $uris{ $_->{'uri'} } = 1 } @{ $prefs->get('libraryalbums') || [] };
	map { $uris{ $_->{'uri'} } = 1 } @{ $prefs->get('librarytracks') || [] };	
}

sub contains {
	return $uris{$_[1]};
}

sub _add {
	my ($uri, $type, $entry) = @_;

	return if $uris{$uri};

	$log->info("add: $uri: " . join(", ", map { "$_ => $entry->{$_}" } keys %$entry));

	$uris{$uri} = 1;

	my @entries = @{$prefs->get("library$type")};
	push @entries, $entry;

	@entries = sort { $a->{'name'} cmp $b->{'name'} } @entries;

	$prefs->set("library$type", \@entries);
}

sub _del {
	my ($uri, $type) = @_;

	return if !$uris{$uri};

	$log->info("delete: $uri");

	my @remaining;

	for my $item (@{$prefs->get("library$type")}) {
		if ($item->{'uri'} ne $uri) {
			push @remaining, $item;
		}
	}

	$prefs->set("library$type", \@remaining);

	delete $uris{ $uri };
}

sub addArtist {
	my ($class, $name, $uri) = @_;
	_add($uri, 'artists', { uri => $uri, name => $name } );
}

sub addAlbum {
	my ($class, $album, $artist, $uri, $cover) = @_;
	_add($uri, 'albums',  { uri => $uri, name => $album, artist => $artist, cover => $cover });
}

sub addTrack {
	my ($class, $track, $album, $artist, $uri, $cover) = @_;
	_add($uri, 'tracks', { uri => $uri, name => $track, artist => $artist, album => $album, cover => $cover });
}

sub delArtist { _del($_[1], 'artists') }
sub delAlbum { _del($_[1], 'albums') }
sub delTrack { _del($_[1], 'tracks') }

sub backup {
	my ($class, $filename) = @_;

	my $json = {
		'ver'     => 1, # version 1 of backup
		'artists' => $prefs->get('libraryartists'),
		'albums'  => $prefs->get('libraryalbums'),
		'tracks'  => $prefs->get('librarytracks'),
	};

	$log->info("saving backup");

	return write_file($filename, encode_json($json));
}

sub restore {
	my ($class, $filename) = @_;

	my $json = eval { decode_json(read_file($filename)) };

	if ($json && $json->{'ver'} == 1) {

		$log->info("restoring backup version 1");

		$prefs->set('libraryartists', $json->{'artists'} || []);
		$prefs->set('libraryalbums',  $json->{'albums'} || []);
		$prefs->set('librarytracks',  $json->{'tracks'} || []);

		$class->init;

		return 1;
	}

	return 0;
}

1;
