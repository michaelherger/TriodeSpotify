package Plugins::SpotifyProtocolHandler::Plugin;

# Plugin to play spotify streams using helper app & libspotify
#
# (c) Adrian Smith (Triode), 2010, 2011 - see license.txt for details
#     Modified by Michael Herger to only use the ProtocolHandler, 2015
#
# The plugin relies on a separate binary spotifyd which is linked to libspotify

use strict;

use File::Spec::Functions;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.spotify');

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
		require Plugins::SpotifyProtocolHandler::Mixer;
		
		Plugins::SpotifyProtocolHandler::Mixer->init();

		if ( !$INC{'Slim/Plugin/SpotifyLogi/Plugin.pm'} ) {
			$log->error("The official Logitech Squeezebox Spotify plugin should be enabled, or some functionality might be limited.");
		}

		my $arch = Slim::Utils::OSDetect->details->{'binArch'};

		# hack for Synology archnames meaning binary dirs don't get put on findBin path
		if ($arch =~ /^MARVELL/) {
			Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'arm-linux' ));
		}
		elsif ($arch =~ /X86|CEDARVIEW|EVANSPORT/) {
			Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'i386-linux' ));
		}
		# freebsd - try adding i386-linux which may work if linux compatibility is installed
		elsif ($^O =~ /freebsd/ && $arch =~ /i386|amd64/) {
			Slim::Utils::Misc::addFindBinPaths(catdir( $class->_pluginDataFor('basedir'), 'Bin', 'i386-linux' ));
		}
	
		if ( main::WEBUI ) {
			Plugins::SpotifyProtocolHandler::Settings->new;
		}
	
		# defer starting helper app until after pref based info is loaded to avoid saving empty prefs if interrupted
		Plugins::SpotifyProtocolHandler::Spotifyd->startD;
	
		Slim::Web::Pages->addPageFunction("^spotifyd.log", \&Plugins::SpotifyProtocolHandler::Spotifyd::logHandler);

		require Plugins::SpotifyProtocolHandler::ProtocolHandler;

		# register a settings item. I don't like that, but we can't hook in to the mysb.com delivered menu.
		Slim::Control::Request::addDispatch(['spotifydontstopthemusicsetting'],[1, 0, 1, \&dontStopTheMusicSetting]);
		
		Slim::Control::Jive::registerPluginMenu([{
			text    => 'PLUGIN_SPOTIFY_PROTOCOLHANDLER',
			id      => 'settingsSpotifyAudoDJ',
			node    => 'settings',
			window  => { 
				'icon-id' => Slim::Web::ImageProxy::proxiedImage(Slim::Plugin::SpotifyLogi::Plugin->_pluginDataFor('icon')),
			},
			weight  => 1,
			actions => {
				go => {
					cmd => ['spotifydontstopthemusicsetting'],
					player => 0
				},
			},
		}]);
	}
}

sub shutdownPlugin {
	if ($INC{'Plugins/SpotifyProtocolHandler/Spotifyd.pm'}) {
		Plugins::SpotifyProtocolHandler::Spotifyd->shutdownD;
	}
}

sub dontStopTheMusicSetting {
	my $request = shift;
	my $client  = $request->client();

	$request->addResult('offset', 0);
	$request->addResult('count', 1);

	$request->setResultLoopHash('item_loop', 0, {
		text => $client->string('PLUGIN_SPOTIFY_DONT_STOP_THE_MUSIC'),
		checkbox => $prefs->client($client)->get('neverStopTheMusic') ? 1 : 0,
		actions => {
			on => {
				player => 0,
				cmd => [ 'playerpref', 'plugin.spotify:neverStopTheMusic', 1 ]
			},
			off => {
				player => 0,
				cmd => [ 'playerpref', 'plugin.spotify:neverStopTheMusic', 0 ]
			},
		},
	});
	
	$request->setStatusDone()
}

*_pluginDataFor = \&Slim::Plugin::Base::_pluginDataFor;

1;
