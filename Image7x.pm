package Plugins::Spotify::Image7x;

use strict;

use HTTP::Status qw(RC_OK RC_NOT_FOUND RC_SERVICE_UNAVAILABLE);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::Spotify::Image;

use constant EXP_TIME => 60 * 60 * 24 * 7; # expire in one week

use constant MAX_IMAGE_REQUEST => 5;       # max images to fetch from spotifyd at once
use constant IMAGE_REQUEST_TIMEOUT1 => 30; # max time to queue
use constant IMAGE_REQUEST_TIMEOUT2 => 35; # max time to wait for response

my $prefs = preferences('plugin.spotify');
my $log   = logger('plugin.spotify');

my $resizer = Slim::Utils::Versions->compareVersions($::VERSION, 7.6) < 0 ? "Slim::Utils::ImageResizer" : "Slim::Utils::GDResizer";

eval "use $resizer";

my @fetchQ;   # Q of images to fetch
my %fetching; # hash of images being fetched

my $id = 0;

sub init {
	Slim::Web::Pages->addRawFunction('/spotifyimage', \&handler);
}

sub handler {
	my ($httpClient, $response) = @_;

	my $path = $response->request->uri;

	# work round problem in web playlist mode - 7.5
	$path =~ s/cover\.jpg_(\d+)x(\d+)_o\.png/cover_$1x$2_o\.jpg/;
	$path =~ s/cover\.jpg_(\d+)x(\d+)_o\.gif/cover_$1x$2_o\.jpg/;
	
	# work round problem in web playlist mode - 7.6
	$path =~ s/\.jpg\.png/\.jpg/;

	$path =~ /\/spotifyimage\/(.*?)\/cover  # spotify image hex id
			(?:_(X|\d+)x(X|\d+))? # width and height are given here, e.g. 300x300
			(?:_([sSfFpcom]))?    # resizeMode, given by a single character
			(?:_([\da-fA-F]+))?   # background color, optional
			\.jpg$
			/ix;	

	my $image = $1;
	my $needsResize = defined $2 || defined $3 || defined $4 || defined $5 || 0;
	my $resizeParams = $needsResize ? [ $2, $3, $4, $5 ] : undef;

	if (!$image || $image !~ /^spotify:image/) {

		$log->info("bad image request - sending 404, path: $path");

		$response->code(RC_NOT_FOUND);
		$response->content_length(0);

		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \'', 1, 0);

		return;
	}

	$id = ($id + 1) % 10_000;

	$image = Plugins::Spotify::Image->getLargeImage($image, $resizeParams);

	$log->info("queuing image id: $id request: $image (resizing: $needsResize)");

	push @fetchQ, { id => $id, timeout => time() + IMAGE_REQUEST_TIMEOUT1, path => $path, 
					httpClient => $httpClient, response => $response, resizeP => $resizeParams, image => $image,
				  };

	$log->debug(sub { "fetchQ: " . (scalar @fetchQ) . " fetching: " . (scalar keys %fetching) });

	if (scalar keys %fetching < MAX_IMAGE_REQUEST) {

		_fetch();

	} else {

		# handle case where we don't appear to get a callback for an async request and it has timed out
		for my $key (keys %fetching) {

			if ($fetching{$key}->{'timeout'} < time()) {

				$log->debug("stale fetch entry - closing");

				my $entry = delete $fetching{$key};

				_sendUnavailable($entry->{'httpClient'}, $entry->{'response'});

				_fetch();
			}
		}
	}
}

sub _fetch {
	my $entry;

	while (!$entry && @fetchQ) {

		 $entry = shift @fetchQ;

		 if (!$entry->{'httpClient'}->connected) {
			 $entry = undef;
			 next;
		 }

		 if ($entry->{'timeout'} < time()) {
			 _sendUnavailable($entry->{'httpClient'}, $entry->{'response'});
			 $entry = undef;
		 } 
	}

	return unless $entry;

	my $image = $entry->{'image'};

	$log->info("fetching image: $image");

	$entry->{'timeout'} = time() + IMAGE_REQUEST_TIMEOUT2;

	$fetching{ $entry->{'id'} } = $entry;

	Slim::Networking::SimpleAsyncHTTP->new(
		\&_gotImage, \&_gotError, $entry
	)->get(Plugins::Spotify::Spotifyd->uri("$image/cover.jpg"));
}

sub _gotImage {
	my $http = shift;
	my $httpClient = $http->params('httpClient');
	my $response   = $http->params('response');
	my $resizeP    = $http->params('resizeP');
	my $path       = $http->params('path');
	my $id         = $http->params('id');

	my $body;

	if ($httpClient->connected) {

		$response->code(RC_OK);
		$response->content_type('image/jpeg');
		
		if ($resizeP) {
			
			my ($w, $h, $m, $bg) = @{$resizeP};
			
			$log->info("resizing image, w: $w h: $h m: $m bg: $bg");
			
			eval {
				($body, undef)  = $resizer->resize(
					original => $http->contentRef,
					format   => 'jpg',
					width    => $w,
					height   => $h,
					mode     => $m,
					bgcolor  => $bg,
					faster   => !preferences('server')->get('resampleArtwork'),
				   );
			};
		}
		
		$response->header('Cache-Control' => 'max-age=' . EXP_TIME);
		$response->expires(time() + EXP_TIME);
		
		use bytes;
		$response->content_length($body ? length($$body) : length($http->content));

		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, $body || $http->contentRef, 1, 0);
	}

	delete $fetching{ $id };

	_fetch();
}

sub _gotError {
	my $http = shift;
	my $error = shift;
	my $httpClient = $http->params('httpClient');
	my $response   = $http->params('response');
	my $id         = $http->params('id');

	$log->warn("error: $error");

	_sendUnavailable($httpClient, $response);

	delete $fetching{ $id };

	_fetch();
}

sub _sendUnavailable {
	my $httpClient = shift;
	my $response   = shift;

	if ($httpClient->connected) {

		$response->code(RC_SERVICE_UNAVAILABLE);
		$response->header('Retry-After' => 10);
		$response->content_length(0);
		
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \'', 1, 0);
	}

	Plugins::Spotify::Spotifyd->countError;
}

sub uri {
	return "spotifyimage/$_[1]/cover.jpg";
}

1;
