package Plugins::Spotify::SinglePlaylist;

use strict;

use base qw(Plugins::Spotify::ParserBase);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $log = logger("plugin.spotify");
my $prefs = preferences("plugin.spotify");

use constant MENU => \&Plugins::Spotify::Plugin::level;

sub request {
	my ($class, $args, $session) = @_;

	my $uri = $session->{'uri'} || $args->{'search'};

	return "$uri/playlists.json";
}

sub result {
	my ($class, $json, $args, $session) = @_;

	my @menu;

	if ($json->{'error'}) {

		$log->warn("error: $json->{error}");

		return $class->error('PLUGIN_SPOTIFY_PLAYLIST_ERROR');

	} elsif (($session->{'recent'} || $session->{'others'}) && $json->{'owner'}) {

		Plugins::Spotify::Recent->updateRecentPlaylists("$json->{owner}: $json->{name}", $json->{'uri'});
														
		push @menu, {
			'name'  => string('PLUGIN_SPOTIFY_REMOVE_FROM_LIST'),
			'url'  => sub {
				my ($client, $callback) = @_;
				$log->info("removing playlist $session->{uri} from recent list");
				Plugins::Spotify::Recent->removeRecentPlaylists($session->{'uri'});
				$callback->( [{
					type        => 'text',
					name        => string('PLUGIN_SPOTIFY_PLAYLIST_REMOVED'),
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

	my $i = 0;

	for my $track (@{$json->{'tracks'} || []}) {

		my $artist = join(", ", map { $_->{'name'} } @{$track->{'artists'}});

		$log->debug("track $track->{name} by $artist");

		my $playlist = $json->{'uri'};

		# disable playlist editting for inbox and playlists of other users
		if ($json->{'owner'} || $session->{'uri'} eq 'inbox') {
			$playlist = undef;
		}

		my $playuri;

		# pass special case of inbox or starred for playalbum
		if ($session->{'playalbum'} && $session->{'uri'} =~ /starred|inbox/) {
			$playuri = $session->{'uri'};
		} elsif ($session->{'playalbum'}) {
			$playuri = $json->{'uri'};
		} else {
			$playuri = $track->{'uri'};
		}
		
		my $menu = {
			name  => $track->{'name'} . " " . string('BY') . " " . $artist,
			type  => 'audio',
			url   => $track->{'uri'},
			icon  => Plugins::Spotify::Image->uri($track->{'cover'}),
			line1 => $track->{'name'},
			line2 => $artist . " \x{2022} " . $track->{'album'},
			itemActions => $class->actions({ play => 1, info => 1, uri => $track->{'uri'}, 
											 playuri => $playuri,
											 ind => $session->{'playalbum'} ? $i : undef,
											 playlist => $playlist,
										 }),
		};
		
		push @menu, $menu;

		$i++;
	}

	if ($session->{'isWeb'} && scalar @menu >= 2) {
		my $playuri = $session->{'uri'} =~ /starred|inbox/ ? $session->{'uri'} : $json->{'uri'};
		unshift @menu, {
			name  => string('ALL_SONGS'),
			type  => 'audio',
			itemActions => $class->actions({ play => 1, uri => $playuri }),
		};
	}

	return \@menu;
}

sub cacheable { 0 }

1;
