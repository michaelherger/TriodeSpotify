package Plugins::Spotify::Image78;

use strict;

use Slim::Web::Graphics;
use Slim::Web::ImageProxy;

use Plugins::Spotify::Image;
use Plugins::Spotify::Spotifyd;

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

	$url = Plugins::Spotify::Image->getLargeImage($url, \@resizeParams);
	
	return Plugins::Spotify::Spotifyd->uri("$url/cover.jpg");
}

sub uri {
	return "imageproxy/$_[1]/image.jpg";
}

1;
