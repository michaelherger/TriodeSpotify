package Plugins::SpotifyProtocolHandler::Plugin;

# Plugin to play spotify streams using helper app & libspotify
#
# (c) Adrian Smith (Triode), 2010, 2011 - see license.txt for details
#     Modified by Michael Herger to only use the ProtocolHandler, 2015
#
# The plugin relies on a separate binary spotifyd which is linked to libspotify

use strict;
use base 'Slim::Plugin::Base';

use File::Spec::Functions;

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

		require Plugins::SpotifyProtocolHandler::Settings;
		require Plugins::SpotifyProtocolHandler::Spotifyd;

		if ( !$INC{'Slim/Plugin/SpotifyLogi/Plugin.pm'} ) {
			$log->error("The official Logitech Squeezebox Spotify plugin should be enabled, or some functionality might be limited.");
		}

		# hack for Synology archnames meaning binary dirs don't get put on findBin path
		my $arch = Slim::Utils::OSDetect->details->{'binArch'};
		if ($arch =~ /^MARVELL/) {
			Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'arm-linux' ));
		}
		if ($arch =~ /X86|CEDARVIEW|EVANSPORT/) {
			Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'i386-linux' ));
		}
	
		# freebsd - try adding i386-linux which may work if linux compatibility is installed
		if ($^O =~ /freebsd/ && Slim::Utils::OSDetect->details->{'binArch'} =~ /i386|amd64/) {
			Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'i386-linux' ));
		}
	
		if ( main::WEBUI ) {
			Plugins::SpotifyProtocolHandler::Settings->new;
		}
	
		# defer starting helper app until after pref based info is loaded to avoid saving empty prefs if interrupted
		Plugins::SpotifyProtocolHandler::Spotifyd->startD;
	
		Slim::Web::Pages->addPageFunction("^spotifyd.log", \&Plugins::SpotifyProtocolHandler::Spotifyd::logHandler);
		
		# hack to get menu for ip3k players - it's being hidden by default
		if (Slim::Utils::Versions->compareVersions($::VERSION, 7.8) >= 0) {
			Slim::Buttons::Common::addMode($class->modeName, $class->getFunctions, sub { $class->setMode(@_) });
			$class->addNonSNApp();
		}

		require Plugins::SpotifyProtocolHandler::ProtocolHandler;
	}
}

sub shutdownPlugin {
	if ($INC{'Plugins/SpotifyProtocolHandler/Spotifyd.pm'}) {
		Plugins::SpotifyProtocolHandler::Spotifyd->shutdownD;
	}
}

sub playerMenu {}

sub menu { Slim::Utils::Versions->compareVersions($::VERSION, 7.8) < 0 ? 'apps' : undef }

sub getDisplayName { 'SPOTIFY' }

sub setMode {
	my ( $class, $client, $method ) = @_;

	if ($method eq 'pop') {

		Slim::Buttons::Common::popMode($client);
		return;
	}

	my $name = $class->getDisplayName();
	
	my $title = (uc($name) eq $name) ? $client->string( $name ) : $name;
	
	my %params = (
		header   => $name,
		modeName => $name,
		url      => Slim::Networking::SqueezeNetwork->url('/api/spotify/v1/opml'),
		title    => $title,
		timeout  => 35,
	);

	Slim::Buttons::Common::pushMode( $client, 'xmlbrowser', \%params );
	
	# we'll handle the push in a callback
	$client->modeParam( handledTransition => 1 );
}

1;
