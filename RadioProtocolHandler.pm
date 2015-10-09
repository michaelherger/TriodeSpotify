package Plugins::Spotify::RadioProtocolHandler;

use strict;

Slim::Player::ProtocolHandlers->registerHandler(spotifyradio => __PACKAGE__);

sub overridePlayback {
	my ( $class, $client, $url ) = @_;

	if ($url =~ /^spotifyradio:genre:(.*)$/) {

		$client->execute(["spotifyradio", "genre", $1]);

		return 1;
	}

	return undef;
}

sub canDirectStream { 0 }

sub isRemote { 0 }

sub contentType {
	return 'spotifyradio';
}

sub getIcon {
	return Plugins::Spotify::Plugin->_pluginDataFor('icon');
}


1;
