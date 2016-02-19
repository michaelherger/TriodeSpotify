package Plugins::SpotifyProtocolHandler::Settings;

use strict;
use base qw(Slim::Web::Settings);

use JSON::XS::VersionOneAndTwo;
use File::Spec::Functions qw(:ALL);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

use Plugins::SpotifyProtocolHandler::Spotifyd;

my $prefs = preferences('plugin.spotify');
my $log   = logger('plugin.spotifyprotocolhandler');
my $jsver;

$prefs->init({ username => 'username', 
			   bitrate => '320', httpport => '9005', loglevel => 'INFO', agree => 0,
			   nootherstreaming => 0, volnorm => 1, nocache => 0,
});

$prefs->setValidate('num', qw(httpport));

# 1 & 2 removed

$prefs->migrate(3, sub { 
	$prefs->set('password', pwEncode($prefs->get('password')));
	1;
});

$prefs->migrate(4, sub { 
#	# this download is used to count the number of installs of the plugin, it only occurs once
#	my $arch = Slim::Utils::OSDetect::OS();
#	Slim::Networking::SimpleAsyncHTTP->new(sub {}, sub {})->get("http://triodeplugins.googlecode.com/files/SpotifyCounter2-$arch");
	1;
});

$prefs->migrate(5, sub {
	# set any existing password in libspotify and then remove from prefs file
	if (my $pw = $prefs->get('password')) {
		setPassword($pw, 'encoded');
		$prefs->remove('password');
	}
	1;
});

sub new {
	$jsver = Plugins::SpotifyProtocolHandler::Plugin->_pluginDataFor('version') || int(rand(1000000));
	return shift->SUPER::new(@_);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTIFY_PROTOCOLHANDLER');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/SpotifyProtocolHandler/settings/basic.html');
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	my $restarting;

	if ($params->{'saveSettings'}) {

		if ($params->{'agree'}) {

			$prefs->set('agree', $params->{'agree'});

		} else {

			if (
				($params->{'username'} ne $prefs->get('username')) || 
				($params->{'bitrate'}  ne $prefs->get('bitrate'))  ||
				($params->{'httpport'} ne $prefs->get('httpport')) ||
				($params->{'loglevel'} ne $prefs->get('loglevel')) ||
				(($params->{'volnorm'} ? 1 : 0) ne $prefs->get('volnorm')) ||
				(($params->{'nocache'} ? 1 : 0) ne $prefs->get('nocache'))
			) {

				$log->debug("username changed") if $params->{'username'} ne $prefs->get('username');
				$log->debug("bitrate changed") if $params->{'bitrate'}  ne $prefs->get('bitrate');
				$log->debug("loglevel changed") if $params->{'loglevel'} ne $prefs->get('loglevel');
				$log->debug("volnorm changed") if ($params->{'volnorm'} ? 1 : 0) ne $prefs->get('volnorm');
				$log->debug("nocache changed") if ($params->{'nocache'} ? 1 : 0) ne $prefs->get('nocache');

				$prefs->set('username', $params->{'username'});
				$prefs->set('bitrate',  $params->{'bitrate'});
				$prefs->set('httpport', $params->{'httpport'});
				$prefs->set('loglevel', $params->{'loglevel'});
				$prefs->set('volnorm',  $params->{'volnorm'} ? 1 : 0);
				$prefs->set('nocache',  $params->{'nocache'} ? 1 : 0);
				
				Plugins::SpotifyProtocolHandler::Spotifyd->restartD;
				
				$restarting = 1;
			}

			if ($params->{'password'} ne '') {
				my $pw = delete $params->{'password'};
				setPassword($pw, undef, sub { $class->handler($client, $params, $callback, @args) });
				return undef;
			}

			my $val = $params->{nootherstreaming} ? 1 : 0;
			if ($val ne $prefs->get('nootherstreaming')) {
				$prefs->set('nootherstreaming', $val);
			}
		}
	}

	$params->{'running'} = Plugins::SpotifyProtocolHandler::Spotifyd->alive;

	if (!$params->{'running'}) {

		if (Slim::Utils::OSDetect::OS() eq 'win') {
			$params->{'hint'} = string('PLUGIN_SPOTIFY_WINHINT');
		}

		if (Slim::Utils::OSDetect::OS() eq 'unix') {
			$params->{'hint'} = string('PLUGIN_SPOTIFY_UNIXHINT');
		}
	}

	$params->{'otherhandler'} = Plugins::SpotifyProtocolHandler::ProtocolHandler->otherHandler;
	$params->{'spotifyduri'}  = Plugins::SpotifyProtocolHandler::Spotifyd->uri;
	$params->{'show_volnorm'} = Slim::Utils::OSDetect->details->{'binArch'} ne 'arm-linux';
	$params->{'helpername'}   = Plugins::SpotifyProtocolHandler::Spotifyd->helperName;
	$params->{'jsver'}        = $jsver;
	$params->{'password'}     = '';

	for my $param(qw(username bitrate httpport loglevel agree nootherstreaming
				     volnorm nocache)) {
		$params->{ $param } = $prefs->get($param);
	}

	if ($params->{'running'} || $restarting) {

		my $try;
		my $retry = 5;
		my $tnow  = Time::HiRes::time();
		my $statusUrl = Plugins::SpotifyProtocolHandler::Spotifyd->uri("status.json") . ($restarting ? "?login" : "");

		$try = sub {

			$log->info("fetching status: $statusUrl");

			Slim::Networking::SimpleAsyncHTTP->new(

				sub {
					$params->{'running'} = 1;
					$params->{'status'} = eval { from_json($_[0]->content) };
					if (!$restarting || $params->{'status'}->{'logged_in'} || !$retry--) {
						$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
					} else {
						Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.3, $try);
					}
				}, 

				sub {
					$log->info("error fetching status: $_[1], retries left: $retry");
					if ( Time::HiRes::time() - $tnow > 30 || !$retry-- ) {
						$callback->($client, $params, $class->SUPER::handler($client, $params), @args);				
					} else {
						Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.3, $try);
					}
				},

				{ timeout => 15 },

			   )->get($statusUrl);
		};

		$try->();
		return;
	}

	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);

	return undef;
}

sub setPassword {
	my ($password, $encoded, $cb) = @_;

	$cb ||= sub {};

	my $url = Plugins::SpotifyProtocolHandler::Spotifyd->uri("setpassword?pw=" . (!$encoded ? pwEncode($password) : $password));
	my $retry = 3;
	my $try;
	
	$try = sub {
		$log->info("attempting to set password");
		
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $json = eval { from_json($_[0]->content) };
				if ($json && $json->{'type'} && $json->{'type'} eq 'setpassword') {
					if ($json->{'success'} && $json->{'success'} eq 'actioned') {
						$log->info("password set");
						$cb->();
						return;
					}
					$log->warn("failed to set password: $json->{success}");
				} else {
					$log->warn("failed to set password");
				}
				if (--$retry) {
					$log->info("retrying, retries left: $retry");
					Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 3, $try);
				}
				$cb->();
			},
			sub {
				if (--$retry) {
					$log->info("error: $_[1], retries left: $retry");
					Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 3, $try);
				} else {
					$log->warn("failed to set password");
					$cb->();
				}
			},
			{ timeout => 15 },
		)->get($url);
	};

	$try->();
}

sub pwEncode {
	use bytes;
	my @plain    = unpack("C*", shift || '');
	my @scramble = unpack("C*", "PQblVcv1xt6LRkIKha819L3tvjTUZPdVmcu0h61AOo0IHT1az89Gz4OAjox4JZC");
	my $encoded  = '';

	while (my $c = shift @plain) {
		if (scalar @scramble) {
			$c ^= shift @scramble;
		}
		$encoded .= sprintf("%%%02x", $c);
	}
	return $encoded;
}

1;
