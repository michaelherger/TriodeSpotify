package Plugins::Spotify::TrackBrowse;

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
	return "$session->{uri}/browse.json";
}

sub result {
	my ($class, $json, $args, $session) = @_;

	$log->debug("track $json->{name}");

	my $artist = join(", ", map { $_->{'name'} } @{$json->{'artists'}});
			
	return [ {
		name  => $json->{'name'} . " " . string('BY') . " " . $artist,
		type  => 'audio',
		url   => $json->{'uri'},
		icon  => Plugins::Spotify::Image->uri($json->{'cover'}),
		line1 => $json->{'name'},
		line2 => $json->{'artist'} . " \x{2022} " . $json->{'album'},
		itemActions => $class->actions({ play => 1, info => 1, uri => $json->{'uri'} }),
	} ];
}

1;
