package Plugins::Spotify::ParserBase;

use strict;

use JSON::XS::VersionOneAndTwo;
use XML::Simple;
use Tie::Cache::LRU;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;

my $log = logger("plugin.spotify");

use constant CACHE_TIME => 300; # cache browse results for 300 secs

sub actions {
	my $class = shift;
	my $opts  = shift || {};

	my $base = delete $opts->{'base'};
	my $info = delete $opts->{'info'};
	my $play = delete $opts->{'play'};
	my $items = delete $opts->{'items'};
	
	my %actions = ();
	my %params  = %$opts;
	
	if ($base) {
		$actions{'commonVariables'}	= [ uri => 'uri', ind => 'ind', playuri => 'playuri' ];
	}

	if ($info) {
		$actions{'info'} = { command => [ "spotifyinfocmd", 'items' ], fixedParams => { %params } };
	}

	if ($items) {
		$actions{'items'} = { command => [ "spotifyitemcmd", 'items' ], fixedParams => { %params } };
	}

	if ($play) {
		$actions{'play'}  = { command => ['spotifyplcmd'], fixedParams => { cmd => 'load', %params },  };
		$actions{'add'}   = { command => ['spotifyplcmd'], fixedParams => { cmd => 'add',  %params },  };
		$actions{'insert'}= { command => ['spotifyplcmd'], fixedParams => { cmd => 'insert', %params } };
		if ($base) {
			$actions{'playall'} = $actions{'play'};
			$actions{'addall'}  = $actions{'add'};
		}
	}

	return \%actions;
}

tie my %cache, 'Tie::Cache::LRU', 10;

sub get {
	my ($class, $args, $session, $callback) = @_;

	my $request = $class->request($args, $session);
	my $params  = $class->params;
	my $cacheable = $class->cacheable;

	my $raw     = delete $params->{'raw'};
	my $xml     = delete $params->{'xml'};
	my $json    = !($raw || $xml);
	my $direct  = delete $params->{'direct'};
	my $retry   = !exists $params->{'retry'} || $params->{'retry'};
	my $timeout = $params->{'timeout'} || 35;
	my $url     = $direct ? $request : Plugins::Spotify::Spotifyd->uri($request);

	if ($cacheable && $cache{$request} && (time() - $cache{$request}->{'time'}) < CACHE_TIME) {

		$log->info("query: $url using cached response");

		$callback->($class->result($cache{$request}->{'data'}, $args, $session));
		return;
	}

	$log->info("query: $url timeout: $timeout retry: $retry");

	$timeout += Time::HiRes::time();

	my $try;
	$try = sub {
		
		Slim::Networking::SimpleAsyncHTTP->new(

			sub {
				if ($json) {
					my $json = eval { from_json($_[0]->content) };
					if ($@) {
						$log->warn("bad json: $@");
						$callback->($class->error("$@"));
					} elsif ($json->{'error'}) {
						$log->warn("$json->{type}: $json->{error}");
						if ($json->{'error'} eq 'timeout' && $retry) {
							Plugins::Spotify::Spotifyd->countError;
							$log->warn("retrying...");
							my $time = Time::HiRes::time();
							if ($retry && $time < $timeout) {
								$log->debug("retrying: $url");
								Slim::Utils::Timers::setTimer(undef, $time + 1, $try);
								return;
							}
						} 
						if ($json->{'error'} =~ /permanent|timeout/) {
							# try restarting helper if general permanent error or on final timeout
							$log->warn("json response error - restarting helper");
							# note this blocks the server, try to get the error message out first...
							Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, sub { Plugins::Spotify::Spotifyd->restartD });
						}
						$callback->($class->error(string('PLUGIN_SPOTIFY_SPOTIFY_ERROR') . $json->{'error'}));
					} else {
						$cache{$request} = { data => $json, time => time() } if $cacheable;
						$callback->($class->result($json, $args, $session));
					}
				} elsif ($xml) {
					my $xml = eval { XMLin($_[0]->content) };
					if ($@) {
						$log->warn("bad xml: $@");
						$callback->($class->error("$@"));
					} else {
						$cache{$request} = { data => $xml, time => time() } if $cacheable;
						$callback->($class->result($xml, $args, $session));
					}
				} else {
					$cache{$request} = { data => $_[0]->content, time => time() } if $cacheable;
					$callback->($class->result($_[0]->content, $args, $session));
				}
			},

			sub {
				my $error = $_[1];
				my $time = Time::HiRes::time();
				if ($retry && $time < $timeout) {
					$log->debug("retrying: $url");
					Slim::Utils::Timers::setTimer(undef, $time + 5, $try);
				} else {
					$log->warn("error $url: " . $error);
					$callback->($class->error($error));
				}
			},

			$params,

		)->get($url);
	};

	$try->();
}

sub cacheable { 1 }

sub error {
	my $class = shift;
	my $error = shift;

	my $error = Slim::Utils::Strings::getString($error);

	return { type => 'opml', name => "Error", items => [ { type => 'text', name => $error } ] };
}

sub params { { timeout => 35 } }

sub newSession { isWeb => $_[1]->{'isWeb'}, ipeng => $_[1]->{'ipeng'}, playalbum => $_[1]->{'playalbum'} }


# backwards compatability with parser based xmlbrowser approach used in 1.x.0 versions
sub parse {
	my $class = shift;
    my $http  = shift;

    my $params = $http->params('params');
    my $url    = $params->{'url'};
	my $client = $params->{'client'};
	my $item   = $params->{'item'};
	my $pageicon = $params->{'pageicon'};

	my $json = eval { from_json($http->content) };
	if ($@) {
		$log->warn("bad json: $@");
		return;
	}

	if ($json->{'error'}) {
		$log->warn("json response error: " . $json->{'error'});
		return $class->error("Error: " . $json->{'error'});
	}

	my $session = {};

	if ($pageicon) {
		$session->{'isWeb'} = 1;
	}

	Plugins::Spotify::Plugin::addPlayAlbum($client, $session);

	my $ret = $class->result($json, {}, $session);

	if (ref $ret eq 'ARRAY') {
		$ret = {
			name  => $item->{'name'},
			items => $ret,
			type  => 'link',
		};
	}

	# ensure Slim::Formats::XML does not try to cache parsed feed as coderefs can't be serialised
	$ret->{'nocache'} = 1;
	$ret->{'cachetime'} = 0;

	return $ret;
}

1;
