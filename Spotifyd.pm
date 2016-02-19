package Plugins::SpotifyProtocolHandler::Spotifyd;

use strict;

use File::ReadBackwards;
use File::Spec::Functions;
use JSON::XS::VersionOneAndTwo;
use Config;

use Proc::BackgroundSetUser;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.spotify');
my $log   = logger('plugin.spotifyprotocolhandler');

my $spotifyd;
my $helperName;      # location of current helper (pre win32 filename shortening)
my $runningHelper;   # specfic helper which is running
my $spotifydChecker; # timer to test liveness of spotifyd
my $reloginTime;     # time of last relogin

sub init {
	my ( $class, $binFolder ) = @_;

	my $arch = Slim::Utils::OSDetect->details->{'binArch'};

	# hack for Synology archnames meaning binary dirs don't get put on findBin path
	if ($arch =~ /^MARVELL/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $binFolder, 'arm-linux' ));
	}
	elsif ($arch =~ /X86|CEDARVIEW|EVANSPORT/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $binFolder, 'i386-linux' ));
	}
	# freebsd - try adding i386-linux which may work if linux compatibility is installed
	elsif ($^O =~ /freebsd/ && $arch =~ /i386|amd64/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $binFolder, 'i386-linux' ));
	}
	# we need to add the find path for all architectures, as they were not available when the plugin was loaded
	else {
		my @paths = ( catdir($binFolder, $arch), $binFolder );

		if ( $arch =~ /i386-linux/i ) {
 			my $arch = $Config::Config{'archname'};
 			
			if ( $arch && $arch =~ s/^x86_64-([^-]+).*/x86_64-$1/ ) {
				unshift @paths, catdir($binFolder, $arch);
			}
		}
		elsif ( $arch && $arch eq 'armhf-linux' ) {
			push @paths, catdir($binFolder, 'arm-linux');
		}

		Slim::Utils::Misc::addFindBinPaths( @paths );
	}

	$class->startD;
}

sub startD {
	my $class = shift;
	my $specific = shift;

	$reloginTime = 0;

	my @helpers;

	if ($spotifydChecker) {
		Slim::Utils::Timers::killSpecific($spotifydChecker);
	}

	if ($specific) {

		# only try the specific helper which was running
		@helpers = ( $specific );

	} else {

		# else try all appropriate helpers
		@helpers = qw(spotifyd);

		# on linux:
		if (Slim::Utils::OSDetect::OS() eq 'unix') {
			# on 64 bit try 64 bit builds first
			if ($Config::Config{'archname'} =~ /x86_64/) {
				unshift @helpers, qw(spotifyd64 spotifydnoflac64);
			}

			# also try version with no flac dependancy and libspotify 10 version
			push @helpers, qw(spotifydnoflac spotifydnoflac10);

			# on armhf use hf binaries instead of default arm5te binaries
			if ($Config::Config{'archname'} =~ /arm\-linux\-gnueabihf/ ||
				($Config::Config{'archname'} =~ /arm/ && (
					$Config::Config{'lddlflags'} =~ /\-mfloat\-abi=hard/ || 
					$Config::Config{'config_args'} =~ /\-mfloat\-abi=hard/
				))
			   ) {
				@helpers = qw(spotifydhf spotifydnoflachf);
			}
		}
	}

	my $count = scalar @helpers;
	my $try;

	$try = sub {
		my $helper = shift @helpers || return;

		$helperName = Slim::Utils::Misc::findbin($helper) || do {
			$log->debug("helper app: $helper not found");
			if (! --$count) {
				$log->error("no spotifyd helper found");
			}
			$try->();
			return;
		};

		# this converts to windows shortened paths
		my $helperPath = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($helperName);
		
		$class->_writeConfig("$helperPath.conf");

		my $logfile = $class->logFile;
	
		if (! -w $logfile) {
			$log->warn("unable to write log file: $logfile");
		}
		
		$log->info("starting $helperPath $logfile");

		$spotifyd = undef;

		eval { $spotifyd = Proc::BackgroundSetUser->new({ 'die_upon_destroy' => 1 }, $helperPath, $logfile); };

		if ($@) {
			$log->warn($@);
		}

		if ($spotifydChecker) {
			Slim::Utils::Timers::killSpecific($spotifydChecker);
		}

		$spotifydChecker = Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 1,

			sub {
				my $alive = $spotifyd && $spotifyd->alive;

				$log->info("$helperPath: " . ($alive ? "running" : "failed"));

				if (!$alive) {

					$try->();

				} else {

					$runningHelper = $helper;

					$spotifydChecker = Slim::Utils::Timers::setTimer($class, time() + 30, \&_checkAlive);

					if ($helper =~ /noflac/) {

						$log->info("started in noflac mode");
						delete $Slim::Player::TranscodingHelper::commandTable{'sflc-flc-*-*'};
						delete $Slim::Player::TranscodingHelper::capabilities{'sflc-flc-*-*'};
					}
				}
			}
		);
	};
	
	$try->();
}

sub _checkAlive {
	my $class = shift;

	if ($spotifyd && !$spotifyd->alive) {

		$log->warn("$runningHelper has failed restarting");

		$class->startD($runningHelper);
		return;
	}

	$spotifydChecker = Slim::Utils::Timers::setTimer($class, time() + 30, \&_checkAlive);
}

sub shutdownD {
	my $class = shift;

	if ($spotifydChecker) {
		Slim::Utils::Timers::killSpecific($spotifydChecker);
		$spotifydChecker = undef;
	}

	if ($spotifyd && $spotifyd->alive) {
		
		$log->info("killing spotifyd");
		$spotifyd->die;
	}
}

sub alive {
	return undef if !defined $spotifyd;

	return $spotifyd->alive ? 1 : 0;
}

sub helperName { $helperName }

sub _writeConfig {
	my ($class, $configFile) = @_;

	open(FILE, '>:utf8', $configFile) || do {

		$log->error("can't write helper config at $configFile");
		return;
	};

	my $cachedir = catdir( preferences('server')->get('cachedir'), 'spotifycache' );

	# create cachedir as libspotify will only do this for cached data, not settings
	if (!-d $cachedir) {
		mkdir($cachedir);
	}

	# loglevel first so we can log other config values
	print FILE ("loglevel: " . $prefs->get('loglevel') . "\n");
	print FILE ("username: " . $prefs->get('username') . "\n");
	print FILE ("cachedir: " . $cachedir .               "\n");
	print FILE ("bitrate: "  . $prefs->get('bitrate')  . "\n");
	print FILE ("volnorm: "  . ($prefs->get('volnorm') ? "1" : "0")  . "\n");
	print FILE ("httpport: " . $prefs->get('httpport') . "\n");
	print FILE ("cliport: "  . preferences('plugin.cli')->get('cliport') . "\n");
	print FILE ("cacheaudio: " . ($prefs->get('nocache') ? "0" : "1") . "\n");
	
	close FILE;

	$log->info("wrote config file: $configFile");
}

sub restartD {
	my $class = shift;

	$class->shutdownD;
	$class->startD;
}

sub relogin {
	my $class = shift;

	$log->warn("requesting relogin");

	Slim::Networking::SimpleAsyncHTTP->new(sub {}, sub {
		my $body;
		
		if ( my $file = File::ReadBackwards->new(logFile()) ) {
			# get the last three lines from the log file
			my $count = 3;
			while ( --$count && (my $line = $file->readline()) ) {
				$body = $line . $body;
			}
			
			$body = "\n...\n$body";
	
			$file->close();			
		};

		$log->error('Login failed - please check your Spotify credentials in LMS. Famous last words from spotifyd:' . $body);
	})->get($class->uri("relogin"));

	$reloginTime = Time::HiRes::time();
}

sub reloginTime { $reloginTime }

sub uri {
	my $class = shift;
	my $suffix = shift || '';

	my $host = Slim::Utils::Network::serverAddr();
	my $port = $prefs->get('httpport');

	return "http://$host:$port/$suffix";
}

sub logFile {
	return catdir(Slim::Utils::OSDetect::dirsFor('log'), "spotifyd.log");
}

sub logHandler {
	my ($client, $params, undef, undef, $response) = @_;

	$response->header("Refresh" => "10; url=" . $params->{path} . ($params->{lines} ? '?lines=' . $params->{lines} : ''));
	$response->header("Content-Type" => "text/plain; charset=utf-8");

	my $body = '';
	my $file = File::ReadBackwards->new(logFile());
	
	if ($file){

		my @lines;
		my $count = $params->{lines} || 100;

		while ( --$count && (my $line = $file->readline()) ) {
			unshift (@lines, $line);
		}

		$body .= join('', @lines);

		$file->close();			
	};

	return \$body;
}

sub get {
	my ($class, $path, $cb, $ecb) = @_;

	my $uri = $class->uri($path);

	$log->info("get: $uri");

	Slim::Networking::SimpleAsyncHTTP->new(

		sub {
			my $json = eval { from_json($_[0]->content) };
			if ($@) {
				$log->warn("bad json: $@");
				$ecb->("$@");
			} elsif ($json->{'success'}) {
				$cb->($json->{'success'});
			} elsif ($json->{'error'}) {
				$ecb->($json->{'error'});
			} else {
				$cb->($json);
			}
		},

		sub { 
			# We'd get the following error if the helper was running, but invalid credentials:
			# "Error reading headers: Server closed connection without sending any data back"
			if ( $_[1] =~ /Server closed connection/i && Time::HiRes::time() - $class->reloginTime > 15 ) {
				$class->relogin();
			}
			
			$log->warn($_[1]);
			$ecb->($_[1])
		},

		{ timeout => 35 }

	)->get($uri);
}

1;
