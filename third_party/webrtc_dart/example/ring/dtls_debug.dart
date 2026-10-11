/// Debug DTLS handshake with Ring camera
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:ring_client_api/ring_client_api.dart' as ring;

import 'peer.dart';

void main() async {
  // Enable verbose logging for ICE and DTLS
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // Show all webrtc logs
    if (record.loggerName.startsWith('webrtc')) {
      print('${record.level.name} [${record.loggerName}] ${record.message}');
    }
  });

  // Load refresh token
  final token = _loadRefreshToken();
  if (token == null) {
    print('Error: Set RING_REFRESH_TOKEN in .env file');
    exit(1);
  }

  print('=== DTLS Debug: Ring Camera Connection ===\n');

  // Connect to Ring
  print('Connecting to Ring API...');
  final ringApi = ring.RingApi(
    ring.RefreshTokenAuth(refreshToken: token),
    options: ring.RingApiOptions(debug: false),
  );

  final cameras = await ringApi.getCameras();
  if (cameras.isEmpty) {
    print('Error: No cameras found');
    exit(1);
  }

  final camera = cameras[0]; // Use same camera as werift (index 0)
  print('Camera: ${camera.name}\n');

  // Create peer connection
  final pc = CustomPeerConnection();

  var connected = false;
  var rtpReceived = false;

  pc.onConnectionState.listen((state) {
    print('\n>>> CONNECTION STATE: $state <<<\n');
    if (state == ring.ConnectionState.connected) {
      connected = true;
    }
  });

  pc.onVideoRtp.listen((rtp) {
    if (!rtpReceived) {
      rtpReceived = true;
      print('\n>>> FIRST VIDEO RTP RECEIVED: ssrc=${rtp.ssrc}, seq=${rtp.sequenceNumber} <<<\n');
    }
  });

  // Start live call
  print('Starting live call...');
  final session = await camera.startLiveCall(
    ring.StreamingConnectionOptions(createPeerConnection: () => pc),
  );

  // Wait for connection
  print('\nWaiting for connection (max 30s)...\n');
  for (var i = 0; i < 30; i++) {
    await Future.delayed(Duration(seconds: 1));
    if (connected) {
      print('\n=== Connected after ${i + 1} seconds ===');
      break;
    }
    if (i % 5 == 4) {
      print('... still waiting (${i + 1}s)');
    }
  }

  if (!connected) {
    print('\n=== FAILED: Connection not established after 30s ===');
  }

  // Wait a bit more for RTP
  await Future.delayed(Duration(seconds: 5));

  print('\n=== Results ===');
  print('Connected: $connected');
  print('RTP received: $rtpReceived');

  session.stop();
  pc.close();
  exit(0);
}

String? _loadRefreshToken() {
  var token = Platform.environment['RING_REFRESH_TOKEN'];
  if (token != null && token.isNotEmpty) return token;

  final envFile = File('.env');
  if (envFile.existsSync()) {
    for (final line in envFile.readAsLinesSync()) {
      if (line.startsWith('RING_REFRESH_TOKEN=')) {
        token = line.substring('RING_REFRESH_TOKEN='.length).trim();
        if (token.isNotEmpty) return token;
      }
    }
  }
  return null;
}
