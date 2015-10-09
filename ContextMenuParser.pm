package Plugins::Spotify::ContextMenuParser;

use strict;

use base qw(Plugins::Spotify::ParserBase);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

my $log = logger("plugin.spotify");

use constant MENU => \&Plugins::Spotify::Plugin::level;

sub request {
	my ($class, $args, $session) = @_;

	my $uri = $session->{'uri'};

	if ($uri =~ /^spotify:track|^spotify:artist|^spotify:album/) {
	   	return "$uri/browse.json";
	} elsif ($uri =~ /^spotify:user:.*:playlist/) {
		return "$uri/playlists.json";
	}
}

sub result {
	my ($class, $json, $args, $session) = @_;
	return $json;
}

sub cacheable { 0 }

1;
