package Plugins::SpotifyProtocolHandler::Plugin;

# Plugin to play spotify streams using helper app & libspotify
#
# (c) Adrian Smith (Triode), 2010, 2011 - see license.txt for details
#     Modified by Michael Herger to only use the ProtocolHandler, 2015
#
# The plugin relies on a separate binary spotifyd which is linked to libspotify

use strict;

use Digest::MD5 qw(md5_hex);
use Digest::SHA1;
use File::Basename qw(basename);
use File::Next;
use File::Spec::Functions;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.spotifyprotocolhandler',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_SPOTIFY_PROTOCOLHANDLER',
}); 

# we only initialize once all plugins are loaded. And then we only continue if Triode's plugin is not installed.
sub postinitPlugin {
	my $class = shift;
	
	if ($INC{'Plugins/Spotify/Plugin.pm'}) {
		$log->error("Triode's Spotify Plugin is installed - no need for the Spotify Protocol Handler plugin.");
	}
	else {
		if ( !$INC{'Slim/Plugin/SpotifyLogi/Plugin.pm'} ) {
			$log->error("The official Logitech Squeezebox Spotify plugin should be enabled, or some functionality might be limited.");
		}
	
		if ( main::WEBUI ) {
			require Plugins::SpotifyProtocolHandler::Settings;
			Plugins::SpotifyProtocolHandler::Settings->new;
		}
	
		# defer starting helper app until after pref based info is loaded to avoid saving empty prefs if interrupted
		# first we'll check whether we got all those files and whether they've been updated
		if ( $class->validateHelperFiles() ) {
			$class->initSpotifyD();
		}
		else {
			$log->error("spotifyd helper files are outdated or missing - updating...");
			$class->getHelperFiles();
		}

		Slim::Web::Pages->addPageFunction("^spotifyd.log", \&Plugins::SpotifyProtocolHandler::Spotifyd::logHandler);

		require Plugins::SpotifyProtocolHandler::ProtocolHandler;
	}
}

sub initSpotifyD {
	my $class = shift;

	require Plugins::SpotifyProtocolHandler::Spotifyd;

	my $arch = Slim::Utils::OSDetect->details->{'binArch'};
	my $binDir = catdir($class->_pluginDataFor('basedir'), 'Bin');

	# hack for Synology archnames meaning binary dirs don't get put on findBin path
	if ($arch =~ /^MARVELL/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $binDir, 'arm-linux' ));
	}
	elsif ($arch =~ /X86|CEDARVIEW|EVANSPORT/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $binDir, 'i386-linux' ));
	}
	# freebsd - try adding i386-linux which may work if linux compatibility is installed
	elsif ($^O =~ /freebsd/ && $arch =~ /i386|amd64/) {
		Slim::Utils::Misc::addFindBinPaths(catdir( $binDir, 'i386-linux' ));
	}
	# we need to add the find path for all architectures, as they were not available when the plugin was loaded
	else {
		my @paths = ( catdir($binDir, $arch), $binDir );

		if ( $arch =~ /i386-linux/i ) {
 			my $arch = $Config::Config{'archname'};
 			
			if ( $arch && $arch =~ s/^x86_64-([^-]+).*/x86_64-$1/ ) {
				unshift @paths, catdir($binDir, $arch);
			}
		}
		elsif ( $arch && $arch eq 'armhf-linux' ) {
			push @paths, catdir($binDir, 'arm-linux');
		}

		Slim::Utils::Misc::addFindBinPaths( @paths );
	}

	Plugins::SpotifyProtocolHandler::Spotifyd->startD;
}

sub shutdownPlugin {
	if ($INC{'Plugins/SpotifyProtocolHandler/Spotifyd.pm'}) {
		Plugins::SpotifyProtocolHandler::Spotifyd->shutdownD;
	}
}

sub validateHelperFiles {
	my ($class) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug('Validate spotifyd helper files');

	my $binFolder = catdir( $class->_pluginDataFor('basedir'), 'Bin' );

	# verify whether we have all the binaries in place 
	my %hashes = map { $_ => 1 } @{$class->_pluginDataFor('hashes') || []};
	my $files  = File::Next::files( $binFolder );
	
	while ( defined ( my $file = $files->() ) ) {
		my @stat = stat($file);
		my $size = $stat[7];
		my $mtime = $stat[9];
		
		$file =~ s/^\Q$binFolder\E\///;
		
		my $hash = md5_hex("$file, $size, $mtime");
		
		delete $hashes{$hash};
		
#		main::DEBUGLOG && $log->is_debug && $log->debug("$hash: $file");
	}
	
	# if we didn't find all file hashes, then return false
	return keys %hashes ? 0 : 1;
}

sub getHelperFiles {
	my ($class) = @_;
	
	my $spotifydVersion = $class->_pluginDataFor('spotifydversion') || return;
	my $binFolder = catdir( $class->_pluginDataFor('basedir'), 'Bin' );
	
	my $file = "SpotifyD-$spotifydVersion.zip";
	my $url = 'http://www.herger.net/_data/' . $file;
	
	$file = catfile($binFolder, $file);

	main::DEBUGLOG && $log->is_debug && $log->debug("Downloading spotifyd helper files from $url to $file");

	Slim::Networking::SimpleAsyncHTTP->new( 
		sub {
			if (-r $file) {
		
				my $sha1 = Digest::SHA1->new;
				open my $fh, '<', $file;
				binmode $fh;
				$sha1->addfile($fh);
				close $fh;
				
				my $shasum = $sha1->hexdigest;
				if ( lc($shasum) ne lc($class->_pluginDataFor('shasum')) ) {
					$log->error("spotifyd digest does not match $file - will not be installed");
					unlink $file;
				} 
				else {
					my $zip;
			
					eval {
						require Archive::Zip;
						$zip = Archive::Zip->new();
					};
			
					if (!defined $zip) {
						$log->error("error loading Archive::Zip $@");
					} 
					elsif (my $zipstatus = $zip->read($file)) {
						$log->warn("error reading zip file $file status: $zipstatus");
					}
					else {
						my $source;
			
						# ignore additional directory information in zip
						foreach ( $zip->membersMatching("^(?:arm|darwin|i386|MSWin32)") ) {
							if ( ($zipstatus = $zip->extractMember($_, catfile($binFolder, $_->fileName)) ) != Archive::Zip::AZ_OK() ) {
								$log->warn("failed to extract " . $_->fileName . "to $binFolder - $zipstatus");
							}
						}
						
						# finally start up SpotifyD
						$class->initSpotifyD();
					}
				}
			}
			else {
				$log->error("spotifyd archive can't be read - will not be installed");
			}
		}, 
		sub {
			$log->error("spotifyd failed to download - $_[1]");
		},
		{ saveAs => $file }
	)->get($url);
}

*_pluginDataFor = \&Slim::Plugin::Base::_pluginDataFor;

1;
