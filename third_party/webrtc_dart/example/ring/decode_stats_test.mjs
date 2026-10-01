/**
 * Standalone Playwright test to check H264 decoding errors with multi-slice encoding
 *
 * Usage:
 *   1. Start the server: dart run recv_via_webrtc.dart
 *   2. Run this test: node decode_stats_test.mjs [chrome|safari]
 */

import { chromium, webkit } from 'playwright';

const HTTP_SERVER_URL = 'http://localhost:8080';
const WS_SERVER_URL = 'ws://localhost:8888';
const TEST_DURATION_MS = 15000; // Run for 15 seconds to collect stats

async function runTest(browserName = 'chrome') {
  console.log(`\nH264 Multi-Slice Decoding Stats Test`);
  console.log(`====================================`);
  console.log(`Browser: ${browserName}`);
  console.log(`Server: ${HTTP_SERVER_URL}`);
  console.log(`Duration: ${TEST_DURATION_MS / 1000}s\n`);

  // Check server is running
  try {
    const resp = await fetch(`${HTTP_SERVER_URL}/status`);
    const status = await resp.json();
    console.log(`[Server] Ring connected: ${status.ringConnected}`);
    console.log(`[Server] Receiving video: ${status.ringReceivingVideo}`);
    console.log(`[Server] RTP packets: ${status.rtpPacketsReceived}`);
    console.log(`[Server] Marker bits (frames): ${status.markerBitsReceived}\n`);

    if (!status.ringReceivingVideo) {
      console.error('Error: Server not receiving video from Ring camera');
      process.exit(1);
    }
  } catch (e) {
    console.error('Error: Server not running. Start with: dart run recv_via_webrtc.dart');
    process.exit(1);
  }

  // Launch browser
  const browserType = browserName === 'safari' || browserName === 'webkit' ? webkit : chromium;
  const browser = await browserType.launch({ headless: true });
  const context = await browser.newContext({
    permissions: ['camera', 'microphone'],
  });
  const page = await context.newPage();

  // Log console messages
  page.on('console', msg => {
    const text = msg.text();
    if (text.includes('TEST_RESULT') || text.includes('STATS')) {
      console.log(`[Browser] ${text}`);
    }
  });

  try {
    // Inject our stats-collecting test page
    await page.setContent(getTestPageHtml());

    // Wait for test to complete
    console.log('[Test] Collecting decoding stats...\n');

    const result = await page.evaluate(async (duration) => {
      return new Promise((resolve) => {
        setTimeout(() => {
          resolve(window.getTestResults());
        }, duration);
      });
    }, TEST_DURATION_MS);

    // Print results
    printResults(result);

    return result;

  } finally {
    await browser.close();
  }
}

function printResults(result) {
  console.log('\n' + '='.repeat(60));
  console.log('DECODING STATS SUMMARY');
  console.log('='.repeat(60));

  if (!result || !result.finalStats) {
    console.log('No stats collected - video may not have started');
    return;
  }

  const s = result.finalStats;

  console.log(`\nFrames:`);
  console.log(`  Received:     ${s.framesReceived}`);
  console.log(`  Decoded:      ${s.framesDecoded}`);
  console.log(`  Dropped:      ${s.framesDropped}`);
  console.log(`  Key frames:   ${s.keyFramesDecoded}`);

  const dropRate = s.framesReceived > 0
    ? ((s.framesDropped / s.framesReceived) * 100).toFixed(2)
    : 0;
  console.log(`  Drop rate:    ${dropRate}%`);

  console.log(`\nFeedback requests (indicates decoder issues):`);
  console.log(`  PLI count:    ${s.pliCount} (Picture Loss Indication)`);
  console.log(`  FIR count:    ${s.firCount} (Full Intra Request)`);
  console.log(`  NACK count:   ${s.nackCount} (Negative Acknowledgment)`);

  console.log(`\nNetwork:`);
  console.log(`  Packets received: ${s.packetsReceived}`);
  console.log(`  Packets lost:     ${s.packetsLost}`);
  console.log(`  Jitter:           ${(s.jitter * 1000).toFixed(2)}ms`);

  console.log(`\nDecoder:`);
  console.log(`  Implementation:   ${s.decoderImplementation}`);
  console.log(`  Total decode time: ${(s.totalDecodeTime * 1000).toFixed(2)}ms`);
  if (s.framesDecoded > 0) {
    console.log(`  Avg decode time:   ${((s.totalDecodeTime / s.framesDecoded) * 1000).toFixed(2)}ms/frame`);
  }

  console.log(`\nRendered frames (requestVideoFrameCallback): ${result.videoFrameCount}`);

  console.log('\n' + '='.repeat(60));

  // Determine pass/fail
  const hasErrors = s.framesDropped > 0 || s.pliCount > 5 || s.firCount > 0;
  if (hasErrors) {
    console.log('RESULT: Decoding issues detected');
    if (s.framesDropped > 0) console.log(`  - ${s.framesDropped} frames dropped`);
    if (s.pliCount > 5) console.log(`  - ${s.pliCount} PLI requests (>5 suggests issues)`);
    if (s.firCount > 0) console.log(`  - ${s.firCount} FIR requests`);
  } else if (s.framesDecoded > 0) {
    console.log('RESULT: No decoding errors detected');
  } else {
    console.log('RESULT: No frames decoded - check connection');
  }
  console.log('='.repeat(60));
}

function getTestPageHtml() {
  return `
<!DOCTYPE html>
<html>
<head><title>Decode Stats Test</title></head>
<body>
  <video id="video" autoplay playsinline muted></video>
  <script>
    let pc;
    let videoFrameCount = 0;
    let statsHistory = [];
    let finalStats = null;

    window.getTestResults = () => ({
      videoFrameCount,
      finalStats,
      statsHistory,
    });

    async function collectStats() {
      if (!pc) return;
      try {
        const stats = await pc.getStats();
        stats.forEach(report => {
          if (report.type === 'inbound-rtp' && report.kind === 'video') {
            finalStats = {
              framesDecoded: report.framesDecoded || 0,
              framesDropped: report.framesDropped || 0,
              framesReceived: report.framesReceived || 0,
              keyFramesDecoded: report.keyFramesDecoded || 0,
              totalDecodeTime: report.totalDecodeTime || 0,
              pliCount: report.pliCount || 0,
              firCount: report.firCount || 0,
              nackCount: report.nackCount || 0,
              packetsReceived: report.packetsReceived || 0,
              packetsLost: report.packetsLost || 0,
              jitter: report.jitter || 0,
              decoderImplementation: report.decoderImplementation || 'unknown',
            };
            statsHistory.push({...finalStats, timestamp: Date.now()});
          }
        });
      } catch (e) {
        console.log('Stats error: ' + e.message);
      }
    }

    async function start() {
      const socket = new WebSocket('${WS_SERVER_URL}');

      await new Promise((resolve, reject) => {
        socket.onopen = resolve;
        socket.onerror = reject;
        setTimeout(() => reject(new Error('WS timeout')), 10000);
      });
      console.log('STATS: WebSocket connected');

      const offer = await new Promise((resolve) => {
        socket.onmessage = (e) => resolve(JSON.parse(e.data));
      });

      pc = new RTCPeerConnection({
        iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
      });

      pc.ontrack = (e) => {
        console.log('STATS: Track received: ' + e.track.kind);
        const video = document.getElementById('video');
        if (!video.srcObject) {
          video.srcObject = new MediaStream();
        }
        video.srcObject.addTrack(e.track);
        video.play().catch(() => {});

        if (e.track.kind === 'video' && video.requestVideoFrameCallback) {
          const countFrames = () => {
            videoFrameCount++;
            video.requestVideoFrameCallback(countFrames);
          };
          video.requestVideoFrameCallback(countFrames);
        }
      };

      pc.onconnectionstatechange = () => {
        console.log('STATS: Connection state: ' + pc.connectionState);
      };

      await pc.setRemoteDescription(offer);
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      await new Promise((resolve) => {
        if (pc.iceGatheringState === 'complete') resolve();
        else pc.onicegatheringstatechange = () => {
          if (pc.iceGatheringState === 'complete') resolve();
        };
        setTimeout(resolve, 3000);
      });

      socket.send(JSON.stringify(pc.localDescription));
      console.log('STATS: Answer sent');

      // Collect stats every second
      setInterval(collectStats, 1000);
    }

    start().catch(e => console.log('STATS: Error: ' + e.message));
  </script>
</body>
</html>
`;
}

// Run
const browserArg = process.argv[2] || process.env.BROWSER || 'chrome';
runTest(browserArg).catch(e => {
  console.error('Fatal error:', e);
  process.exit(1);
});
