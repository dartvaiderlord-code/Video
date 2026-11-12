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
  await context.addInitScript(() => { window.__pcs = []; const Original = window.RTCPeerConnection; window.RTCPeerConnection = class extends Original { constructor(...args) { super(...args); window.__pcs.push(this); } }; });
  const host = await context.newPage(), viewer = await context.newPage();
  const errors = [];
  for (const page of [host, viewer]) page.on('pageerror', e => errors.push(e.message));
  await host.addInitScript(() => {
    if (!navigator.mediaDevices) return; // The certificate interstitial has no capture API.
    window.__realCaptureAvailable = typeof navigator.mediaDevices?.getDisplayMedia === 'function';
    navigator.mediaDevices.getDisplayMedia = async options => {
      window.__requestedCapture = options;
      const canvas = document.createElement('canvas'); canvas.width = 640; canvas.height = 360;
      const ctx = canvas.getContext('2d'); let frame = 0;
      const draw = () => { ctx.fillStyle = `hsl(${frame++ % 360},80%,45%)`; ctx.fillRect(0,0,640,360); ctx.fillStyle = 'white'; ctx.fillText(`Пиратский трактир ${frame}`,30,40); }; draw(); setInterval(draw, 33);
      const stream = canvas.captureStream(30);
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
