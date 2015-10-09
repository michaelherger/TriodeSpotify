// JS selftest functions for spotify plugin

// fetch json feed from cross domain location
function fetch(url, cb) {
	var decode = function(responseText) {
		var p = Ext.util.JSON.decode(responseText);
		if (p) {
			cb(p);
		}
	}

	if (!Ext.isIE) {
		// use XMLHttpRequest for all non IE browsers
		var xhr = new XMLHttpRequest();
		if (xhr) {
			xhr.onreadystatechange = function() {
				if (xhr.readyState == 4) {
					decode(xhr.responseText);
				}
			}
			xhr.open("GET", url, true);
			xhr.send();
			return xhr;
		}
	} else {
		// use XDomainRequest to allow cross domain request on IE
        var xdr = new XDomainRequest();
        if (xdr) {
            xdr.onload = function() {
				decode(xdr.responseText);
			}
            xdr.open("GET", url);
            xdr.send();
			return xdr;
        } else {
			alert("Browser Not Supported - please use IE 8 or newer");
		}
	}
}

// fetch multiple chunked json objects joined with \n from cross domain location
function fetchChunked(url, cb) {
	var lastPos = 0;
	var decode = function(responseText) {
		var data = responseText.substring(lastPos);
		lastPos  = responseText.length;
		// depending on browser we get called with one or more chunks
		// starting chunk may also be empty as we pad for IE to fill buffer
		var json = data.split('\n');
		for (var i in json) {
			var p;
			try { p = Ext.util.JSON.decode(json[i]); } catch (e) {}
			if (p) {
				cb(p);
			}
		}
	}

	if (!Ext.isIE) {
		// use XMLHttpRequest for all non IE browsers
		var xhr = new XMLHttpRequest();
		if (xhr) {
			xhr.onreadystatechange = function() {
				if (xhr.readyState == 3) {
					decode(xhr.responseText);
				}
			}
			xhr.open("GET", url, true);
			xhr.send();
			return xhr;
		}
	} else {
		// use XDomainRequest to allow cross domain request on IE
        var xdr = new XDomainRequest();
        if (xdr) {
            xdr.onprogress = function() {
				decode(xdr.responseText);
			}
            xdr.open("GET", url);
            xdr.send();
			return xdr;
        }
	}
}

// perform server request for player
function serverRequest(playerid, params, cb) {
	var xhr = new XMLHttpRequest();
	if (xhr) {
		xhr.onreadystatechange = function() {
			if (cb && xhr.readyState == 4) {
				var p = Ext.util.JSON.decode(xhr.responseText);
				if (p && p.result) {
					cb(p.result);
				}
			}
		}
		xhr.open("POST", '/jsonrpc.js', true);
		xhr.send(Ext.util.JSON.encode({
			id: 1, 
			method: 'slim.request', 
			params: [ playerid, params ]
		}));
		return xhr;
	}
}

function startSelfTest(spotifyd, playerid) {
	// hide status info
	var tohide = ['helperapp', 'status', 'api', 'hint', 'button'];
	for (var i in tohide) {
		var element = document.getElementById(tohide[i]);
		if (element) {
			element.style.display="none";
		}
	}

	// panel to show our test results in
	var panel = new Ext.Panel({
		title: 'Self Test - Running',
		layout:'table',
		renderTo: 'test',
		width: '500px',
		hideBorders: true,
		layoutConfig: { columns: 2 },
		items: [
			{ id: 'pbar1', xtype: 'progress', width: 450 },
			{ html: '<div id="text1" style="padding: 4px 4px 0px 4px; text-align: center;"></div>', width: 50 },
			{ id: 'pbar2', xtype: 'progress', width: 450 },
			{ html: '<div id="text2" style="padding: 4px 4px 0px 4px; text-align: center;"></div>', width: 50 },
			{ id: 'pbar3', xtype: 'progress', width: 450 },
			{ html: '<div id="text3" style="padding: 4px 4px 0px 4px; text-align: center;"></div>', width: 50 },
			{ id: 'pbar4', xtype: 'progress', width: 450 },
			{ html: '<div id="text4" style="padding: 4px 4px 0px 4px; text-align: center;"></div>', width: 50 },
			{ id: 'pbar5', xtype: 'progress', width: 450 },
			{ html: '<div id="text5" style="padding: 4px 4px 0px 4px; text-align: center;"></div>', width: 50 },
			{ colspan: 2, html: '<div id="summary" style="padding: 4px 4px 0px 4px;"></div>' }
		]
	});

	var updateText = function(id, text) {
		var el = document.getElementById(id);
		if (el) {
			el.innerHTML = text;
		}
	}

	var endTests = function(text, req, to) {
		panel.setTitle("Self Test - Complete");
		if (text) {
			updateText('summary', text);
		}
		if (req) {
			try { req.abort(); } catch (e) {}
		}
		if (to) {
			clearTimeout(to);
		}
	}

	var test1, test2, test3, test4, test5;

	// connect to server and check if logged in
	test1 = function() {
		var req;
		var timeout = setTimeout(function() {
			Ext.getCmp('pbar1').updateProgress(1, "Helper App Not Running");
			updateText('text1', 'FAIL');
			endTests("Help App is not running - please check why", req);
		}, 5000);

		req = fetch(spotifyd + "status.json", function(p) {
			clearTimeout(timeout);
			Ext.getCmp('pbar1').updateProgress(1, "Helper App Running");
			updateText('text1', 'PASS');
			test2();
		});
	};

	// fetch toplist
	test2 = function() {
		var req;
		var timeout = setTimeout(function() {
			Ext.getCmp('pbar3').updateProgress(1, "Failed To Receive Metadata");
			updateText('text3', 'FAIL');
			req.abort();
			test3();
		}, 15000);

		req = fetch(spotifyd + "toplist.json?q=tracks&r=user", function(p) {
			if (p.tracks && p.tracks.length) {
				clearTimeout(timeout);
				Ext.getCmp('pbar3').updateProgress(1, "Spotify Metadata OK");
				updateText('text3', 'PASS');
				test3();
			}
		});
	};

	// check server status
	test3 = function() {
		var req;
		var timeout = setTimeout(function() {
			endTests("", req);
		}, 5000);

		req = fetch(spotifyd + "status.json", function(p) {
			clearTimeout(timeout);
			if (p.logged_in) {
				Ext.getCmp('pbar2').updateProgress(1, "Logged In");
				updateText('text2', 'PASS');
				test4();
			} else {
				Ext.getCmp('pbar2').updateProgress(1, "Not Logged In");
				updateText('text2', 'FAIL');
				endTests("Unable to log in to Spotify: " + p.login_error);
			}
		});
	};

	// streamtest track details
	var dur, samplerate, len, uri, currate;

	// streamtest - no player
	test4 = function() {
		var req;
		var timeout = setTimeout(function() {
			Ext.getCmp('pbar4').updateText("Streaming from Spotify Failed");
			updateText('text4', 'FAIL');
			endTests("Unable to start streaming from Spotify - check connectivity to Spotify", req);
		}, 10000);

		req = fetchChunked(spotifyd + "streamtest.json", function(p) {
			if (!req) {
				return;
			}
			clearTimeout(timeout);
			timeout = setTimeout(function() {
				Ext.getCmp('pbar4').updateText("Streaming from Spotify Stalled");
				updateText('text4', 'FAIL');
				if (currate && currate > samplerate) {
					endTests("Streaming from Spotify stalled before end of track, rate OK", req);
				} else {
					endTests("Streaming from Spotify stalled before end of track, rate LOW", req);
				}
			}, 5000);

			if (!dur && p.duration) {
				dur = p.duration;
			}
			if (!len && dur && p.samplerate) {
				len = dur * p.samplerate / 1000;
				samplerate = p.samplerate;
			}
			if (!uri && p.uri) {
				uri = p.uri;
			}
			if (p.streamed && len) {
				Ext.getCmp('pbar4').updateProgress(p.streamed / len, "Streaming from Spotify");
				currate = p.rate;
			}
			if (p.avgrate) {
				if (p.avgrate > samplerate) {
					Ext.getCmp('pbar4').updateProgress(1, "Streaming from Spotify OK");
					updateText('text4', 'PASS');
					test5();
				} else {
					Ext.getCmp('pbar4').updateProgress(1, "Streaming Rate Low");
					updateText('text4', 'FAIL');
					endTests("Streaming rate from Spotify too LOW (" + p.avgrate + " < " + samplerate +") - check connectivity to Spotify", req);
				}
				req = null;
				clearTimeout(timeout);
				return;
			}
		});
	};

	// streamtest - with player
	test5 = function() {
		if (playerid == "") {
			Ext.getCmp('pbar5').updateText("No Player");
			endTests("Unable to test streaming to player as no player is connected");
			return;
		}

		var req;
		var sentPlay;
		var timeout = setTimeout(function() {
			Ext.getCmp('pbar5').updateText("Streaming to player Failed");
			updateText('text5', 'FAIL');
			endTests("Unable to start streaming to player - check player", req);
		}, 10000);

		req = fetchChunked(spotifyd + uri + "/" + "streamtest.json", function(p) {
			if (!req) {
				return;
			}
			if (sentPlay) {
				clearTimeout(timeout);
				timeout = setTimeout(function() {
					if (currate) {
						Ext.getCmp('pbar5').updateText("Streaming to player Stalled");
						updateText('text5', 'FAIL');
						if (currate > samplerate) {
							endTests("Streaming to player stalled before end of track, rate OK", req);
						} else {
							endTests("Streaming to player stalled before end of track, rate LOW", req);
						}
					} else {
						Ext.getCmp('pbar5').updateText("Unable to stream to player");
						endTests("Streaming test could not start.  This is expected if the player is a Touch or Radio and 'Always Stream via Helper' is not set", req);
					}
				}, 5000);
			}

			// trigger play once streamtest2 in waiting state
			if (p.state && p.state == "waiting") {
				serverRequest(playerid, ['playlist', 'play', uri]);
				sentPlay = true;
				currate = 0;
			}
			// update progress
			if (p.streamed && len) {
				Ext.getCmp('pbar5').updateProgress(p.streamed / len, "Streaming To Player");
				currate = p.rate;
			}
			// stream complete
			if (p.avgrate) {
				if (p.avgrate > samplerate) {
					Ext.getCmp('pbar5').updateProgress(1, "Streaming to Player OK");
					updateText('text5', 'PASS');
					endTests("All tests complete - plugin is working correctly", req, timeout);
				} else {
					Ext.getCmp('pbar5').updateProgress(1, "Streaming to Player Rate Low");
					updateText('text5', 'FAIL');
					endTests("Streaming rate to player too LOW (" + p.avgrate + " < " + samplerate +") - check your local network is able to playback Flac files without audio stuttering", req, timeout);
				}
				req = null;
			}
			// error cases
			if (p.timeout && p.timeout == "no_player") {
				Ext.getCmp('pbar5').updateProgress(0, "Player Unable to Connect");
				updateText('text5', 'FAIL');
				serverRequest(playerid, ['status','-','1','tags:uB'], function(result) {
					if (result.playlist_loop[0] && result.playlist_loop[0].url == uri) {
						// tried to play our track but did not manage to play - likely firewall issue
						endTests("Player did not connect to helper app - check your firewall allows the helper app to receive incoming connections from players on the helper app port defined above", req, timeout);
					} else {
						// did not manage to play our track - likely problem accepting jsonrpc?
						endTests("Playback not started on player", req, timeout);
					}
				});
				req = null;
			}
			if (p.bad_player) {
				// problem with player validation
				Ext.getCmp('pbar5').updateProgress(0, "Unable to authenticate player");
				updateText('text5', 'FAIL');
				endTests("Helper app unable to authenticate player (error: " + p.bad_player + ")", req, timeout);
				req = null;
			}
		});
	};

	// start first test
	test1();
}
