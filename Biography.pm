package Plugins::Spotify::Biography;

use strict;

use base qw(Plugins::Spotify::ParserBase);

use HTML::Entities;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

my $log = logger("plugin.spotify");
my $prefs = preferences("plugin.spotify");

use constant MENU => \&Plugins::Spotify::Plugin::level;

sub request {
	my ($class, $args, $session) = @_;
	return "$session->{artisturi}/bio.txt";
}

sub result {
	my ($class, $text, $args, $session) = @_;

	$text ||= Slim::Utils::Strings::string('PLUGIN_SPOTIFY_NO_BIO_AVAIL');

	$text = Slim::Utils::Unicode::utf8on($text);

	decode_entities($text);
	$text =~ s/<[a-zA-Z\/][^>]*>//gi;

	return {
		'name' => $session->{'artist'},
		'type' => 'opml',
		'items' => [ {
			'name'  => $text,
			'wrap'  => 1,
			'type'  => 'text',
			'items' => [],
		} ],
	};
}

sub params { { timout => 35, raw => 1 } }

1;
