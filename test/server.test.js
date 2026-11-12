import { test } from 'node:test';
import manifest from '../package.json' with {type:'json'};
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { WebSocket } from 'ws';
import { createApp } from '../server.js';

async function setup(t, env = {}) {
  const app = createApp(env);
  await new Promise(r => app.server.listen(0, '127.0.0.1', r));
  t.after(() => app.close());
  const base = `http://127.0.0.1:${app.server.address().port}`;
  async function client(origin = base) {
    const ws = new WebSocket(base.replace('http:', 'ws:') + '/ws', {origin});
    const queue = [], waiters = [];
    ws.on('message', data => { const msg = JSON.parse(data); if (waiters.length) waiters.shift()(msg); else queue.push(msg); });
    await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
    return {ws, send: msg => ws.send(JSON.stringify(msg)), next: async (type) => { for (;;) { const msg = queue.length ? queue.shift() : await new Promise(resolve => waiters.push(resolve)); if (type ? msg.type === type : msg.type !== 'members') return msg; } }};
  }
  return {base, client};
}
test('HTTP assets, CSP and health check', async t => {
  const {base} = await setup(t);
  const page = await fetch(base);
  assert.equal(page.status, 200); assert.match(await page.text(), /Пиратский трактир/);
  assert.match(page.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal((await fetch(base + '/app.js')).status, 200);
  assert.match((await fetch(base + '/pirate-flag.svg')).headers.get('content-type'), /image\/svg\+xml/);
  assert.equal((await fetch(base + '/../server.js')).status, 404);
  assert.equal(await (await fetch(base + '/healthz')).text(), 'ok');
});
test('room authorization, TURN credentials, signaling isolation, viewer limit and teardown', {timeout:10000}, async t => {
  const secret = 'test-secret';
  const {client} = await setup(t, {ACCESS_KEY:'legacy-ignored', MAX_VIEWERS:'1', TURN_URLS:'turn:example.com:3478', TURN_SECRET:secret});
  const host = await client();
  host.send({type:'create', roomCode:'bad'}); assert.equal((await host.next()).type, 'error');
  host.send({type:'create', roomCode:'Морской код 240'}); const room = await host.next();
  assert.equal(room.type, 'created'); assert.equal(room.token.length, 48);
  const turn = room.iceServers[1];
  assert.equal(turn.credential, createHmac('sha1', secret).update(turn.username).digest('base64'));
  const viewer = await client();
  viewer.send({type:'join', room:room.room, token:'bad', roomCode:'Морской код 240'}); assert.equal((await viewer.next()).type, 'error');
  viewer.send({type:'join', room:room.room, token:room.token, roomCode:'wrong-code'}); assert.equal((await viewer.next()).type, 'error');
  viewer.send({type:'join', room:room.room, token:room.token, roomCode:'Морской код 240'}); assert.equal((await viewer.next()).type, 'joined');
  const arrival = await host.next(); assert.equal(arrival.type, 'viewer-joined');
  host.send({type:'signal', to:arrival.id, data:{description:{type:'offer', sdp:'test'}}});
  assert.equal((await viewer.next()).data.description.sdp, 'test');
  viewer.send({type:'signal', to:'untrusted-target', data:{candidate:{candidate:'test-candidate'}}});
  assert.equal((await host.next()).from, arrival.id);
  const extra = await client();
  extra.send({type:'join', room:room.room, token:room.token, roomCode:'Морской код 240'}); assert.equal((await extra.next()).type, 'error');
  host.ws.close(); assert.equal((await viewer.next()).type, 'ended');
  extra.send({type:'join', room:room.room, token:room.token, roomCode:'Морской код 240'}); assert.equal((await extra.next()).type, 'error');
});
test('rejects cross-origin sockets', {timeout:3000}, async t => {
  const {client} = await setup(t);
  await assert.rejects(client('https://unrelated.example'));
});
test('viewer departure informs host', {timeout:3000}, async t => {
  const {client} = await setup(t);
  const host = await client(); host.send({type:'create', roomCode:'Морской код 240'}); const room = await host.next();
  const viewer = await client(); viewer.send({type:'join', room:room.room, token:room.token, roomCode:'Морской код 240'});
  await viewer.next(); const joined = await host.next(); viewer.ws.close();
  const left = await host.next(); assert.equal(left.type, 'viewer-left'); assert.equal(left.id, joined.id);
});

test('room code attempts are limited and room codes are not exposed in invitations', {timeout:5000}, async t => {
  const {client} = await setup(t);
  const host = await client(); host.send({type:'create', roomCode:'my-own-secret'});
  const room = await host.next(); assert.equal(JSON.stringify(room).includes('my-own-secret'), false);
  const viewer = await client();
  for (let i = 0; i < 20; i++) {
    viewer.send({type:'join', room:room.room, token:room.token, roomCode:'wrong-code'});
    assert.match((await viewer.next()).message, /Неверный код/);
  }
  const fresh = await client();
  fresh.send({type:'join', room:room.room, token:room.token, roomCode:'my-own-secret'});
  assert.match((await fresh.next()).message, /30 секунд/);
});

test('authenticated room chat, voice roster and viewer-to-viewer voice stay within the room', {timeout:5000}, async t => {
  const {client} = await setup(t);
  const host = await client(); host.send({type:'create',roomCode:'GOIDA'}); const room = await host.next();
  assert.equal((await host.next('members')).members[0].id, room.id);
  const a = await client(), b = await client();
  a.send({type:'join', room:room.room, token:room.token, roomCode:'GOIDA'}); const joinedA = await a.next();
  b.send({type:'join', room:room.room, token:room.token, roomCode:'GOIDA'}); const joinedB = await b.next();
  await b.next('members');
  a.send({type:'chat', text:'<b>Hello</b>', from:'spoofed'});
  const chat = await b.next('chat'); assert.equal(chat.from,joinedA.id); assert.equal(chat.text,'<b>Hello</b>');
  a.send({type:'voice-state',enabled:true}); b.send({type:'voice-state',enabled:true});
  let roster; do { roster = await b.next('members'); } while (!roster.members.every(m => m.id === room.id || m.voice));
  a.send({type:'voice-signal', to:joinedB.id, from:'spoofed', data:{description:{type:'offer',sdp:'voice'}}});
  const signal = await b.next('voice-signal'); assert.equal(signal.from, joinedA.id);
  const outsider = await client(); outsider.send({type:'create',roomCode:'OTHER'}); const other = await outsider.next(); await outsider.next('members');
  let leaked = false; outsider.ws.on('message', raw => { if (['voice-signal','chat'].includes(JSON.parse(raw).type)) leaked = true; });
  a.send({type:'voice-signal',to:other.id,data:{candidate:{candidate:'private'}}});
  b.send({type:'voice-state',enabled:false}); await b.next('members');
  let voiceAfterLeave = false; b.ws.on('message', raw => { if (JSON.parse(raw).type === 'voice-signal') voiceAfterLeave = true; });
  a.send({type:'voice-signal',to:joinedB.id,data:{candidate:{candidate:'stale'}}});
  await new Promise(r => setTimeout(r, 150)); assert.equal(leaked,false); assert.equal(voiceAfterLeave,false);
});

test('deployed server exposes a no-store version and chat capabilities', async t => {
  const {base} = await setup(t);
  const response = await fetch(base + '/api/version');
  const info = await response.json();
  assert.equal(info.version,manifest.version);
  assert.equal(info.protocol,2);
  assert.deepEqual(info.features,['chat','voice']);
  assert.equal(response.headers.get('x-pirate-tavern-version'), info.version);
  assert.equal(response.headers.get('cache-control'),'no-store');
});
