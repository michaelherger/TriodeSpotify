package Plugins::Spotify::Playlists;

use strict;

use base qw(Plugins::Spotify::ParserBase);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

my $log = logger("plugin.spotify");

use constant MENU => \&Plugins::Spotify::Plugin::level;

sub request {
	my ($class, $args, $session) = @_;
	return $session->{'user'} ? "playlists.json?user=$session->{user}" : "playlists.json";
}

sub result {
	my ($class, $json, $args, $session) = @_;

	my @playlists;

	if (!$session->{'user'}) {

		# add inbox playlist if this is the local user
		push @playlists, {
			'name'        => string('PLUGIN_SPOTIFY_PLAYLIST_INBOX'),
			'url'         => MENU,
			'passthrough' => [ 'SinglePlaylist', { %$session, uri => 'inbox' } ],
			'type'        => 'playlist',
			'itemActions' => $class->actions({ play => 1, uri => 'inbox' }),
		};
	
		# don't appear to be able to fetch other user's starred playlists, restrict to own user at present
		# own user does not have json->{starred} set
		my $starred = $json->{'starred'} ? $json->{'starred'}->{'uri'} : 'starred';
		
		push @playlists, {
			'name'        => string('PLUGIN_SPOTIFY_PLAYLIST_STARRED'),
			'url'         => MENU,
			'passthrough' => [ 'SinglePlaylist', { %$session, uri => $starred } ],
			'type'        => 'playlist',
			'itemActions' => $class->actions({ play => 1, uri => $starred }),
		};
	}

	my @levels = (\@playlists);

	for my $entry (@{$json->{'playlists'}}) {

		if ($entry->{'folder-start'}) {

			$log->debug("folder start: $entry->{name}");

			my $new = [];

			push @{$levels[-1]}, {
				'name'  => $entry->{'name'},
				'items' => $new,
				'type'  => 'opml',
			};

			push @levels, $new;

		} elsif ($entry->{'folder-end'}) {

			$log->debug("folder end");

			pop @levels;

		} else {

			my @menu;
			
			my $uri = $entry->{'uri'};
			my $name = $entry->{'name'} || string('PLUGIN_SPOTIFY_NO_TITLE');
			
			if ($entry->{'user'}) {
				$name = "$entry->{user}: $name";
			}
			
			$log->debug("playlist $name $uri");
			
			push @{$levels[-1]}, {
				'name'        => $name,
				'url'         => MENU,
				'passthrough' => [ 'SinglePlaylist', { %$session, uri => $uri } ],
				'type'        => 'playlist',
				'itemActions' => $class->actions({ info => 1, play => 1, uri => $uri }),
				'play'        => $uri,
			};

		}
	}

	if ($session->{'isWeb'} && !$session->{'user'}) {

		push @playlists, {
			'name'       => string('PLUGIN_SPOTIFY_PLAYLIST_URI'),
			'url'        => MENU,
			'passthrough'=> [ 'SinglePlaylist', { %$session, others => 1 } ],
			'type'       => 'search',
		};
	}

	if (!$session->{'user'}) {
		push @playlists, @{ Plugins::Spotify::Recent->recentPlaylists($session) || [] };
	}

	return \@playlists;
}

sub cacheable { 0 }

1;
