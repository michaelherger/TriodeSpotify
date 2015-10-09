package Plugins::Spotify::LastFM;

use strict;

use base qw(Plugins::Spotify::ParserBase);

use XML::Simple;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $log = logger("plugin.spotify");
my $prefs = preferences("plugin.spotify");

use constant MENU => \&Plugins::Spotify::Plugin::level;

sub request {
	my ($class, $args, $session) = @_;

	if ($session->{'artist'}) {
		return "http://ws.audioscrobbler.com/1.0/artist/" . URI::Escape::uri_escape_utf8($session->{'artist'}) . "/similar.xml";
	}

	if ($session->{'user'}) {
		return "http://ws.audioscrobbler.com/1.0/user/" . URI::Escape::uri_escape_utf8($session->{'user'}) . "/systemrecs.xml";
	}
}

sub result {
	my ($class, $xml, $args, $session) = @_;

	my @menu;

	$log->info("browse lastfm response");

	my @artists;
	my @menu;

	if (ref $xml->{'artist'} eq 'HASH') {

		@artists = keys %{$xml->{'artist'}};

	} else {

		for my $entry (@{$xml->{'artist'}}) {

			if (ref $entry eq 'HASH') { 
				push @artists, $entry->{'name'};
			}
		}
	}

	for my $artist (@artists) {
		push @menu, {
			'name'   => $artist,
			'url'    => MENU,
			'passthrough' => [ 'Search', { $class->newSession($session), query => $artist, artistsearch => 1, exact => 1 } ],
			'type'   => 'link',
		}
	}

	if (ref $xml->{'artist'} eq 'HASH' && (my $user = $prefs->get('lastfmuser'))) {

		# only add this for recommended artist lists, not similar artist lists
		unshift @menu, {
			'name' => string('PLUGIN_SPOTIFY_RECOMMENDED_ARTISTS_MIX'),
			'itemActions' => { play => { command => ['spotifyradio', 'lastfmrec', $user ], }, },
			'type' => 'audio',
		};
	}

	return { items => \@menu };
}

sub params { { timeout => 35, direct => 1, xml => 1 } }

1;
