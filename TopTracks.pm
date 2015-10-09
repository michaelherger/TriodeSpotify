package Plugins::Spotify::TopTracks;

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

	my $top = 2 * ($session->{'top'} || 10); # some additional to allow for duplicate filtering

	return "$session->{artist}/tracks.json?max=$top";
}

sub result {
	my ($class, $json, $args, $session) = @_;

	my @menu;

	# find top tracks ignoring duplicate names
	my $i = 0;
	my $names = {};

	for my $track (@{$json->{'tracks'} || []}) {

		next if $names->{ $track->{'name'} };		

		my $artist = join(", ", map { $_->{'name'} } @{$track->{'artists'}});
		
		$log->info("track $track->{name} by $artist");
			
		my $menu = {
			name  => $track->{'name'},
			type  => 'audio',
			url   => $track->{'uri'},
			icon  => Plugins::Spotify::Image->uri($track->{'cover'}),
			line1 => $track->{'name'},
			line2 => $artist . " \x{2022} " . $track->{'album'},
			itemActions => $class->actions(	$session->{'playalbum'} ? 
				{ info => 1, play => 1, uri => $track->{'uri'}, playuri => $json->{'artisturi'}, top => $session->{'top'}, ind => $i } :
				{ info => 1, play => 1, uri => $track->{'uri'}, playuri => $track->{'uri'} }
			),
		};
		
		push @menu, $menu;

		$names->{ $track->{'name'} } = 1;
		$i++;

		last if $i >= $session->{'top'};
	}

	if ($session->{'isWeb'} && scalar @menu >= 2) {
		unshift @menu, {
			name  => string('ALL_SONGS'),
			type  => 'audio',
			itemActions => $class->actions({ play => 1, uri => $json->{'artisturi'}, top => $session->{'top'} }),
		};
	}

	return {
		cover => $session->{'cover'},
		items => \@menu,
	};
}

1;
