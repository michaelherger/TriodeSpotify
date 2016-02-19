package Plugins::SpotifyProtocolHandler::Plugin;

# Plugin to play spotify streams using helper app & libspotify
#
# (c) Adrian Smith (Triode), 2010, 2011 - see license.txt for details
#     Modified by Michael Herger to only use the ProtocolHandler, 2015
#
# The plugin relies on a separate binary spotifyd which is linked to libspotify

use strict;

use Digest::SHA1 qw(sha1_hex);
use File::Next;
use File::Spec::Functions qw(catdir catfile abs2rel);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.spotifyprotocolhandler',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_SPOTIFY_PROTOCOLHANDLER',
});

my $binFolder;

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

		require Plugins::SpotifyProtocolHandler::Spotifyd;
	
		if ( main::WEBUI ) {
			require Plugins::SpotifyProtocolHandler::Settings;
			Plugins::SpotifyProtocolHandler::Settings->new;
		}

		# we store our binaries in the cache folder, as the Bin folder would be removed during updates
		$binFolder ||= catdir( preferences('server')->get('cachedir'), 'spotifyd' );
		mkdir $binFolder if !-d $binFolder;
		
		# defer starting helper app until after pref based info is loaded to avoid saving empty prefs if interrupted
		# first we'll check whether we got all those files and whether they've been updated
		if ( $class->validateHelperFiles() ) {
			Plugins::SpotifyProtocolHandler::Spotifyd->init($binFolder);
		}
		else {
			$log->error("spotifyd helper files are outdated or missing - updating...");
			$class->getHelperFiles();
		}

		Slim::Web::Pages->addPageFunction("^spotifyd.log", \&Plugins::SpotifyProtocolHandler::Spotifyd::logHandler);

		require Plugins::SpotifyProtocolHandler::ProtocolHandler;
	}
}

sub shutdownPlugin {
	if ($INC{'Plugins/SpotifyProtocolHandler/Spotifyd.pm'}) {
		Plugins::SpotifyProtocolHandler::Spotifyd->shutdownD;
	}
}

sub validateHelperFiles {
	my ($class) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug('Validate spotifyd helper files');

	# verify whether we have all the binaries in place 
	my %hashes = map { $_ => 1 } @{$class->_pluginDataFor('hashes') || []};
	my $files  = File::Next::files( $binFolder );
	
	while ( defined ( my $file = $files->() ) ) {
		my @stat = stat($file);
		my $size = $stat[7];
		my $mtime = $stat[9];
		
		# normalize file paths
		$file = abs2rel($file, $binFolder);
		$file =~ s/\\/\//g;
		
		my $hash = sha1_hex("$file, $size");
		
		delete $hashes{$hash};
		
		main::DEBUGLOG && $log->is_debug && $log->debug("$hash: $file");
	}
	
	# if we didn't find all file hashes, then return false
	return keys %hashes ? 0 : 1;
}

sub getHelperFiles {
	my ($class) = @_;
	
	my $spotifydVersion = $class->_pluginDataFor('spotifydversion') || return;
	
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
						
						unlink $file;
						
						# finally start up SpotifyD
						Plugins::SpotifyProtocolHandler::Spotifyd->init($binFolder);
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
