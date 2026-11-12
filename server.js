import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { randomBytes, createHmac, createHash, timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';

export function createApp(env = process.env) {
  const rooms = new Map();
  const maxViewers = Number(env.MAX_VIEWERS || 6);
  const turnUrls = (env.TURN_URLS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (turnUrls.length && !env.TURN_SECRET) throw new Error('TURN_SECRET is required with TURN_URLS');
  const files = new Map([['/', ['index.html', 'text/html']], ['/app.js', ['app.js', 'text/javascript']], ['/style.css', ['style.css', 'text/css']], ['/pirate-flag.svg', ['pirate-flag.svg', 'image/svg+xml']]]);
  const server = http.createServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'; media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    res.setHeader('Cache-Control', 'no-store');
    if (req.url === '/healthz') { res.writeHead(200, {'Content-Type': 'text/plain'}); return res.end('ok'); }
    const file = files.get(req.url?.split('?')[0]);
    if (!file || !['GET', 'HEAD'].includes(req.method)) { res.writeHead(404); return res.end(); }
    try {
      const data = await readFile(new URL(`./public/${file[0]}`, import.meta.url));
      res.writeHead(200, {'Content-Type': `${file[1]}; charset=utf-8`});
      res.end(req.method === 'HEAD' ? undefined : data);
    } catch { res.writeHead(500); res.end('Internal error'); }
  });
  const wss = new WebSocketServer({noServer: true, maxPayload: 64 * 1024});
  server.on('upgrade', (req, socket, head) => {
    // Set PUBLIC_ORIGIN behind a reverse proxy. Never trust forwarded headers here.
    const expected = env.PUBLIC_ORIGIN || `http://${req.headers.host}`;
    if (req.url !== '/ws' || req.headers.origin !== expected || wss.clients.size >= 800) return socket.destroy();
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
  });
  const send = (ws, msg) => { if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg)); };
  const ice = () => {
    const servers = [{urls: (env.STUN_URLS || 'stun:stun.l.google.com:19302').split(',')}];
    if (turnUrls.length) {
      const username = `${Math.floor(Date.now()/1000) + 43200}:${randomBytes(8).toString('hex')}`;
      servers.push({urls: turnUrls, username, credential: createHmac('sha1', env.TURN_SECRET).update(username).digest('base64')});
    }
    return servers;
  };
  wss.on('connection', ws => {
    ws.id = randomBytes(12).toString('hex'); ws.alive = true;
    ws.on('error', () => {});
    ws.on('pong', () => { ws.alive = true; });
    let count = 0, since = Date.now();
    const authTimer = setTimeout(() => { if (!ws.room) ws.close(1008, 'Join timeout'); }, 15000);
    ws.on('message', raw => {
      if (Date.now() - since > 10000) { count = 0; since = Date.now(); }
      if (++count > 300) return ws.close(1008, 'Rate limit');
      let msg;
      try { msg = JSON.parse(raw); } catch { return ws.close(1008, 'Invalid JSON'); }
      if (!msg || typeof msg !== 'object') return;
      if (!ws.room) {
        if (msg.type === 'create') {
          const code = typeof msg.roomCode === 'string' ? msg.roomCode.trim() : '';
          if (code.length < 4 || code.length > 64) return send(ws, {type:'error', message:'Код комнаты должен содержать от 4 до 64 символов.'});
          if (rooms.size >= 100) return send(ws, {type:'error', message:'Сервер занят. Попробуйте позже.'});
          const id = randomBytes(12).toString('hex'), token = randomBytes(24).toString('hex');
          ws.host = true; ws.room = id;
          const salt = randomBytes(16).toString('hex');
          const codeHash = createHash('sha256').update(salt + code).digest();
          rooms.set(id, {host:ws, token, salt, codeHash, attempts:0, attemptsSince:Date.now(), viewers:new Map()});
          clearTimeout(authTimer);
          send(ws, {type:'created', room:id, token, iceServers:ice(), maxViewers});
        } else if (msg.type === 'join') {
          const room = rooms.get(msg.room);
          if (!room || room.token !== msg.token) return send(ws, {type:'error', message:'Комната не найдена или ссылка недействительна.'});
          if (Date.now() - room.attemptsSince >= 30000) { room.attempts = 0; room.attemptsSince = Date.now(); }
          if (room.attempts >= 20) return send(ws, {type:'error', message:'Слишком много неверных кодов. Попробуйте через 30 секунд.'});
          const code = typeof msg.roomCode === 'string' ? msg.roomCode.trim() : '';
          const supplied = createHash('sha256').update(room.salt + code).digest();
          if (code.length < 4 || code.length > 64 || !timingSafeEqual(supplied, room.codeHash)) {
            room.attempts++;
            return send(ws, {type:'error', message:'Неверный код комнаты.'});
          }
          if (room.viewers.size >= maxViewers) return send(ws, {type:'error', message:'Комната заполнена.'});
          ws.room = msg.room; room.viewers.set(ws.id, ws); clearTimeout(authTimer);
          send(ws, {type:'joined', id:ws.id, iceServers:ice()});
          send(room.host, {type:'viewer-joined', id:ws.id});
        }
        return;
      }
      const room = rooms.get(ws.room);
      if (!room) return;
      if (msg.type === 'signal' && msg.data && typeof msg.data === 'object') {
        const target = ws.host ? room.viewers.get(msg.to) : room.host;
        if (target) send(target, {type:'signal', from:ws.id, data:msg.data});
      }
    });
    ws.on('close', () => {
      clearTimeout(authTimer);
      const room = rooms.get(ws.room); if (!room) return;
      if (ws.host) {
        rooms.delete(ws.room);
        for (const viewer of room.viewers.values()) { send(viewer, {type:'ended'}); viewer.close(); }
      } else { room.viewers.delete(ws.id); send(room.host, {type:'viewer-left', id:ws.id}); }
    });
  });
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) { if (!ws.alive) ws.terminate(); else { ws.alive = false; ws.ping(); } }
  }, 15000);
  heartbeat.unref();
  return {server, close: async () => {
    clearInterval(heartbeat);
    for (const ws of wss.clients) ws.terminate();
    await new Promise(resolve => wss.close(resolve));
    await new Promise(resolve => server.close(resolve));
  }};
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = createApp();
  app.server.listen(Number(process.env.PORT || 3000), '0.0.0.0', () => console.log('Пиратский трактир — порт', process.env.PORT || 3000));
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => app.close().then(() => process.exit(0)));
}
