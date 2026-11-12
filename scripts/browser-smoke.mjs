// Synthetic capture tests transport, rendering, and audio without a system picker.
// Real screen/audio capture still needs manual testing on the sender's OS.
import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { createApp } from '../server.js';
const roomCode = process.env.SMOKE_ROOM_CODE || 'Моя пиратская каюта';
const app = createApp({ TURN_URLS:process.env.TURN_URLS, TURN_SECRET:process.env.TURN_SECRET});
await new Promise(resolve => app.server.listen(0, '127.0.0.1', resolve));
const origin = process.env.SMOKE_ORIGIN || `http://127.0.0.1:${app.server.address().port}`;
let browser;
try {
  browser = await chromium.launch({headless:true, executablePath:process.env.CHROMIUM_PATH || undefined, args:['--no-sandbox','--autoplay-policy=no-user-gesture-required']});
  const context = await browser.newContext();
  await context.addInitScript(() => {
    if (!navigator.mediaDevices) return;
    window.__micRequests = 0;
    navigator.mediaDevices.getUserMedia = async () => {
      window.__micRequests++;
      const audio = new AudioContext(); const osc = audio.createOscillator();
      const gain = audio.createGain(); gain.gain.value = .05;
      const dest = audio.createMediaStreamDestination(); osc.connect(gain).connect(dest); osc.start(); await audio.resume();
      return dest.stream;
    };
  });
  await context.addInitScript(() => { window.__pcs = []; const Original = window.RTCPeerConnection; window.RTCPeerConnection = class extends Original { constructor(...args) { super(...args); window.__pcs.push(this); } }; });
  const host = await context.newPage(), viewer = await context.newPage();
  const errors = [];
  for (const page of [host, viewer]) page.on('pageerror', e => errors.push(e.message));
  await host.addInitScript(() => {
    if (!navigator.mediaDevices) return; // The certificate interstitial has no capture API.
    window.__realCaptureAvailable = typeof navigator.mediaDevices?.getDisplayMedia === 'function';
    navigator.mediaDevices.getDisplayMedia = async options => {
      window.__requestedCapture = options;
      const canvas = document.createElement('canvas'); canvas.width = 1280; canvas.height = 720;
      const ctx = canvas.getContext('2d'); let frame = 0;
      const pixels = ctx.createImageData(1280,720), data = new Uint32Array(pixels.data.buffer); let seed = 1;
      const draw = () => { for (let i = 0; i < data.length; i++) { seed = (Math.imul(seed,1664525) + 1013904223) | 0; data[i] = 0xff000000 | (seed & 0xffffff); } ctx.putImageData(pixels,0,0); frame++; }; draw(); setInterval(draw, 1000/60);
      const stream = canvas.captureStream(60);
      const audio = new AudioContext(); const osc = audio.createOscillator();
      const dest = audio.createMediaStreamDestination(); osc.connect(dest); osc.start(); await audio.resume();
      stream.addTrack(dest.stream.getAudioTracks()[0]); return stream;
    };
  });
  async function open(page, url) {
    try { await page.goto(url); } catch (error) {
      if (process.env.SMOKE_ACCEPT_SELF_SIGNED !== '1' || !error.message.includes('ERR_CERT_AUTHORITY_INVALID')) throw error;
      // Exercise the same site-specific certificate exception as a user.
      // No global TLS bypass or ignoreHTTPSErrors context is used.
      await page.locator('#details-button').click();
      await page.locator('#proceed-link').click();
      await page.waitForURL(u => u.href === new URL(url).href);
      await page.waitForLoadState();
    }
  }
  await open(host, origin);
  assert.equal(await host.evaluate(() => window.isSecureContext && window.__realCaptureAvailable), true);
  assert.match(await host.title(), /Пиратский трактир/);
  await host.locator('#room-code').fill(roomCode);
  await host.locator('#quality').selectOption('1440');
  await host.locator('#fps').selectOption('240');
  await host.locator('#bitrate').selectOption('50');
  await host.screenshot({path:'/tmp/pirate-host-setup.png', fullPage:true});
  await host.locator('#start').click();
  await host.locator('#invite').waitFor({state:'visible'});
  assert.equal(await host.evaluate(() => window.__requestedCapture.video.frameRate.ideal), 240);
  assert.equal(await host.evaluate(() => window.__requestedCapture.video.height.ideal), 1440);
  const link = await host.locator('#link').inputValue();
  assert.match(link, /#room=.+&token=/);
  await open(viewer, link);
  await viewer.locator('#join-code').fill('wrong-code'); await viewer.locator('#join').click();
  await viewer.waitForFunction(() => document.getElementById('status').textContent.includes('Неверный код'));
  await viewer.locator('#join-code').fill(roomCode); await viewer.locator('#join').click();
  await viewer.waitForFunction(() => {
    const v = document.getElementById('video');
    return v.videoWidth >= 320 && v.currentTime > 1 && v.srcObject?.getAudioTracks().length === 1 && v.srcObject?.getVideoTracks().length === 1;
  }, null, {timeout:20000});
  await viewer.waitForFunction(async () => {
    const stats = [...(await window.__pcs[0].getStats()).values()];
    return stats.some(s => s.type === 'inbound-rtp' && s.kind === 'audio' && s.bytesReceived > 0 && s.totalAudioEnergy > 0) && stats.some(s => s.type === 'inbound-rtp' && s.kind === 'video' && s.framesDecoded > 5);
  });
  const encoding = await host.evaluate(() => window.__pcs[0].getSenders().find(s => s.track.kind === 'video').getParameters().encodings[0]);
  assert.equal(encoding.maxBitrate, 50000000);
  assert.equal(encoding.maxFramerate, 240);
  // Measure actual encoded video on BOTH ends, not a configured maximum.
  const bytes = page => page.evaluate(async () => {
    const stats = [...(await window.__pcs[0].getStats()).values()];
    const r = stats.find(s => (s.type === 'outbound-rtp' || s.type === 'inbound-rtp') && s.kind === 'video');
    return {bytes:r.bytesSent ?? r.bytesReceived, time:r.timestamp, frames:r.framesEncoded ?? r.framesDecoded, fps:r.framesPerSecond};
  });
  const before = await Promise.all([bytes(host), bytes(viewer)]);
  await host.waitForTimeout(8000);
  const after = await Promise.all([bytes(host), bytes(viewer)]);
  const rates = after.map((r,i) => (r.bytes-before[i].bytes)*8/(r.time-before[i].time)/1000);
  console.log('High-motion RTP Mbps (sender, receiver):', rates, 'actual FPS:', after.map(r => r.fps));
  assert.ok(rates.every(r => r > 5), `Actual video must exceed the reported 2.5 Mbps ceiling: ${rates}`);
  await host.locator('#chat details').evaluate(e => { e.open = true; });
  await viewer.locator('#chat details').evaluate(e => { e.open = true; });
  await host.locator('#chat-input').fill('<script>pirate</script>'); await host.locator('#chat-form button').click();
  await viewer.waitForFunction(() => document.getElementById('chat-messages').textContent.includes('<script>pirate</script>'));
  assert.equal(await viewer.locator('#chat-messages script').count(), 0);
  assert.equal(await host.evaluate(() => window.__micRequests), 0);
  assert.equal(await viewer.evaluate(() => window.__micRequests), 0);
  // Three audio participants prove viewer-to-viewer voice routing as well.
  const second = await context.newPage(); second.on('pageerror', e => errors.push(e.message)); await open(second, link);
  await second.locator('#join-code').fill(roomCode); await second.locator('#join').click();
  await second.locator('#voice-toggle').waitFor({state:'visible'});
  for (const page of [host, viewer, second]) await page.locator('#voice-toggle').click();
  for (const page of [host, viewer, second]) await page.waitForFunction(async () => {
    const audioPeers = window.__pcs.filter(pc => pc.getSenders().some(s => s.track?.kind === 'audio') && !pc.getSenders().some(s => s.track?.kind === 'video'));
    if (audioPeers.length < 2) return false;
    return (await Promise.all(audioPeers.map(async pc => [...(await pc.getStats()).values()].some(s => s.type === 'inbound-rtp' && s.kind === 'audio' && s.totalAudioEnergy > 0)))).filter(Boolean).length >= 2;
  }, null, {timeout:20000});
  assert.equal(await viewer.evaluate(() => window.__micRequests), 1);
  await viewer.locator('#mic-toggle').click(); assert.match(await viewer.locator('#mic-toggle').textContent(), /Включить/);
  await viewer.locator('#voice-toggle').click();
  await host.waitForFunction(() => document.getElementById('voice-members').textContent.split(',').length === 2);
  await second.locator('#stop').click(); await second.close();
  console.log('PASS: optional microphone, three-way voice RTP + audio energy, mute and leave.');


  assert.match(await host.locator('#count').textContent(), /1 зрителей/);
  await viewer.waitForFunction(() => document.getElementById('stats').textContent.includes('соединение') || document.getElementById('stats').textContent.includes('TURN'));
  console.log(await viewer.locator('#stats').textContent());
  await viewer.screenshot({path: process.env.SMOKE_SCREENSHOT || '/tmp/screenroom-viewer.png', fullPage:true});
  await host.locator('#stop').click();
  await viewer.waitForFunction(() => document.getElementById('status').textContent.includes('Автор завершил'));
  assert.deepEqual(errors, []);
  console.log('PASS: room creation, invitation, WebRTC video frames + audio track, connection stats, teardown, no browser errors.');
  const mobile = await context.newPage(); await mobile.setViewportSize({width:390,height:844}); await open(mobile, origin);
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await mobile.screenshot({path:'/tmp/pirate-mobile.png', fullPage:true});
  await context.close();
} finally { await browser?.close(); await app.close(); }
