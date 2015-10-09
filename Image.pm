package Plugins::Spotify::Image;

use strict;

use vars qw(@ISA);
use Tie::Cache::LRU;

use Slim::Utils::Log;

my $log;

BEGIN {
	$log = logger('plugin.spotify'); 

	if (Slim::Utils::Versions->compareVersions($::VERSION, 7.8) < 0) {
		$log->info("using Image7x");
		require Plugins::Spotify::Image7x;
		push @ISA, 'Plugins::Spotify::Image7x';
	} else {
		$log->info("using Image78");
		require Plugins::Spotify::Image78;
		push @ISA, 'Plugins::Spotify::Image78';
	}
}

tie our %largeImageMap, 'Tie::Cache::LRU', 500;

sub getLargeImage {
	my ($class, $image, $resizeParams) = @_;

	if ($resizeParams && $resizeParams->[0] > 250 && $resizeParams->[1] > 250 && $largeImageMap{ $image }) {

		$log->info("Converting to large image: $image -> $largeImageMap{$image}");

		return $largeImageMap{$image};
	}
	
	return $image;
}

1;
