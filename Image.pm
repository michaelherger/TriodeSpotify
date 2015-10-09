package Plugins::Spotify::Image;

use strict;

use Tie::Cache::LRU;

tie our %largeImageMap, 'Tie::Cache::LRU', 500;

use Slim::Utils::Log;
use Slim::Web::Graphics;
use Slim::Web::ImageProxy;

use Plugins::Spotify::Image;
use Plugins::Spotify::Spotifyd;

my $log = logger('plugin.spotify');

sub init {
	Slim::Web::ImageProxy->registerHandler(
		match => qr/spotify:image:/,
		func  => \&resizeHandler,
	);
}

sub resizeHandler {
	my ($url, $spec) = @_;

	my @resizeParams = Slim::Web::Graphics->parseSpec($spec);
	
	# "full size" (no size params) shall return the large image if possible
	$resizeParams[0] ||= 9999;
	$resizeParams[1] ||= 9999;

	$url = __PACKAGE__->getLargeImage($url, \@resizeParams);

	if (scalar @resizeParams && $resizeParams[0] > 250 && $resizeParams[1] > 250 && $largeImageMap{ $url }) {

		$log->info("Converting to large image: $url -> $largeImageMap{$url}");

		$url = $largeImageMap{$url};
	}
	
	return Plugins::Spotify::Spotifyd->uri("$url/cover.jpg");
}

sub uri {
	return "imageproxy/$_[1]/image.jpg";
}

1;
