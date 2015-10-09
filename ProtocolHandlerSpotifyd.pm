package Plugins::Spotify::ProtocolHandlerSpotifyd;

use strict;

use base qw(Slim::Formats::RemoteStream);

use IO::Socket qw(:crlf);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use constant PREFETCH_TIME => 30; # prefetch next track 30 secs before end of current track

my $id = 0; # unique id for track being played

my $prefetch; # timer for prefetch of next track

my $prefs = preferences('plugin.spotify');
my $log   = logger('plugin.spotify');

sub bufferThreshold { 80 }

sub getMetadataFor {
	my $class = shift;
	Plugin::Spotify::ProtocolHandler->getMetadataFor(@_);
}

sub requestString {
	my ($class, $client, $url, undef, $seekdata) = @_;

	my $song = $client->streamingSong;
	my $start = 0;

	if (my $newtime = $seekdata->{'timeOffset'}) {

		$start = int($newtime * 1000);

		if ($song->startOffset != $newtime) {
		
			$song->startOffset($newtime);
		
			$client->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
		}

	} else {

		# initiate prefetch of next track
		$class->prefetchNext($client, $song->duration);
	}

	my $trackuri = $song->currentTrack->url;
	$trackuri =~ s{^spotify://}{spotify:};

	my $playerid = $client->id;
	my $sync     = $client->controller()->activePlayers();
	my $format   = $client->master()->streamformat();

	my $sessId   = $song->pluginData()->{'id'} || ++$id;

	# increment id if we have already played this id on this client
	# handles rew mid track and jumps in current track
	my $cid = $client->id;

	if (exists $song->pluginData()->{$cid} && $song->pluginData()->{$cid} == $sessId) {
		$sessId = ++$id;
	}

	$song->pluginData()->{'id'} = $sessId;
	$song->pluginData()->{$cid} = $sessId;

	$playerid =~ s/:/%3A/g; # uri escape playerid
	
	my $fmtstring = $format eq 'flc' ? 'stream.flc' : 'stream.pcm';

	my $path = "$trackuri/$fmtstring?player=$playerid&start=$start&sync=$sync&id=$id";

	$log->info("$path");

	my $requestString = "GET $path SPOTSTREAM/1.0" . $CRLF;

	if (preferences('server')->get('authorize')) {

		$client->password(Slim::Player::Squeezebox::generate_random_string(20));
				
		my $password = join '', map { sprintf("%02x", $_) } unpack("C*", $client->password);
		
		$requestString .= "Authorization: $password" . $CRLF;
	}

	$requestString .= $CRLF;

	return $requestString;
}

sub prefetchNext {
	my ($class, $client, $duration) = @_;

	return if Slim::Player::Sync::isSlave($client);

	my $controller = $client->controller;

	my $urlOrObj = Slim::Player::Playlist::song($client, $controller->nextsong);

	my $uri = blessed($urlOrObj) ? $urlOrObj->url : $urlOrObj;

	$uri =~ s{^spotify://}{spotify:};

	if ($prefetch) {
		Slim::Utils::Timers::killSpecific($prefetch);
	}

	if ($uri =~ /^spotify:track/) {

		my $prefetchIn = $duration > PREFETCH_TIME ? $duration - PREFETCH_TIME : PREFETCH_TIME;

		$log->info("scheduling prefetch of next track: $uri in $prefetchIn");

		$prefetch = Slim::Utils::Timers::setTimer(__PACKAGE__, time() + $prefetchIn, 
			sub {
				$log->info("prefetching: $uri");
				Plugins::Spotify::Spotifyd->get("$uri/prefetch.json", sub {}, sub {});
				$prefetch = undef;
			}
		);
	}
}

sub parseDirectHeaders {
	my ($class, $client, $url, @headers) = @_;

	my $format = $client->master()->streamformat();

	return (undef, undef, undef, undef, $format);
}


1;
