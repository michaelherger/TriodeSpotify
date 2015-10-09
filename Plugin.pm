package Plugins::Spotify::Plugin;

# Plugin to play spotify streams using helper app & libspotify
#
# (c) Adrian Smith (Triode), 2010, 2011 - see license.txt for details
#
# The plugin relies on a separate binary spotifyd which is linked to libspotify

use strict;
use base 'Slim::Plugin::OPMLBased';

use JSON::XS::VersionOneAndTwo;
use File::Spec::Functions;

use Slim::Utils::Log;

use Slim::Utils::Strings qw(string cstring);

use Plugins::Spotify::Settings;
use Plugins::Spotify::Spotifyd;
use Plugins::Spotify::Image;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.spotify',
	'defaultLevel' => 'WARN',
	'description'  => string('PLUGIN_SPOTIFY'),
}); 

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin();

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

	Plugins::Spotify::Settings->new;

	# defer starting helper app until after pref based info is loaded to avoid saving empty prefs if interrupted
	Plugins::Spotify::Spotifyd->startD;

	Slim::Web::Pages->addPageFunction("^spotifyd.log", \&Plugins::Spotify::Spotifyd::logHandler);

	Plugins::Spotify::Image->init();
}

sub postinitPlugin {
	require Plugins::Spotify::ProtocolHandler;
}

sub shutdownPlugin {
	Plugins::Spotify::Spotifyd->shutdownD;
}

sub playerMenu {}

sub getDisplayName { 'PLUGIN_SPOTIFY' }

1;
