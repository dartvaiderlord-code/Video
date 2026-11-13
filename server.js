import http from 'node:http';
import {AbordageRelay} from './abordage.js';
import manifest from './package.json' with {type:'json'};

export const SERVER_INFO = Object.freeze({version:manifest.version, protocol:2, features:['chat', 'voice', 'abordage-1']});
import { readFile } from 'node:fs/promises';
import { randomBytes, randomInt, createHmac, createHash, timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';

// More names than the 800-connection server limit: active crewmates are unique.
const pirateFirstNames = [
  'Джек', 'Билли', 'Сэм', 'Мэри', 'Том', 'Энн', 'Педро', 'Гарри',
  'Жак', 'Лиззи', 'Морган', 'Гектор', 'Флинт', 'Бонни', 'Чарли', 'Иван',
  'Фрэнсис', 'Хью', 'Роджер', 'Диего', 'Грейс', 'Джеймс', 'Леон', 'Лукас',
  'Фрэнк', 'Клод', 'Эдвард', 'Ник', 'Альваро', 'Пьер', 'Патрик', 'Барт',
];
const pirateNicknames = [
  'Ромовый Ус', 'Кривой Компас', 'Пустая Бочка', 'Гроза Камбуза',
  'Дырявый Парус', 'Три Глотка', 'Чёрный Порох', 'Последний Сухарь',
  'Гроза Сельди', 'Соль За Ухом', 'Попутный Ветер', 'Звонкая Монета',
  'Тихий Бунт', 'Счастливый Крюк', 'Хитрый Краб', 'Верный Кортик',
  'Двойное Дно', 'Сухопутный Ужас', 'Семь Морей', 'Спящий Штурман',
  'Потерянный Карман', 'Сбитый Курс', 'Медный Дублон', 'Острый Язык',
  'Пропавший Обед', 'Золотой Зуб', 'Карманный Шторм', 'Непотопляемый Тост',
  'Сытый Кракен', 'Тайный Запас', 'Капитанский Сквозняк', 'Шторм В Кружке',
];
const pirateNames = pirateFirstNames.flatMap(first => pirateNicknames.map(nick => `${first} «${nick}»`));
function crewName(room) {
  const used = new Set([...room.viewers.values()].map(peer => peer.name));
  const available = pirateNames.filter(name => !used.has(name));
  return available[randomInt(available.length)];
}

export function createApp(env = process.env) {
  const rooms = new Map();
  const relay = new AbordageRelay({port:Number(env.ABORDAGE_PORT || 0),publicPort:Number(env.ABORDAGE_PUBLIC_PORT || 0),host:env.ABORDAGE_HOST});
  relay.ready.catch(error => server.emit('error',error));
  const maxViewers = Number(env.MAX_VIEWERS || 6);
  const turnUrls = (env.TURN_URLS || '').split(',').map(s => s.trim()).filter(Boolean);
  if (turnUrls.length && !env.TURN_SECRET) throw new Error('TURN_SECRET is required with TURN_URLS');
  const files = new Map([['/', ['index.html', 'text/html']], ['/app.js', ['app.js', 'text/javascript']], ['/video-quality.js', ['video-quality.js', 'text/javascript']], ['/room-chat.js', ['room-chat.js', 'text/javascript']], ['/style.css', ['style.css', 'text/css']], ['/pirate-flag.svg', ['pirate-flag.svg', 'image/svg+xml']]]);
  const server = http.createServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'; media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Pirate-Tavern-Version', SERVER_INFO.version);
    if (req.url?.split('?')[0] === '/api/version' && ['GET','HEAD'].includes(req.method)) {
      res.writeHead(200, {'Content-Type':'application/json; charset=utf-8'});
      return res.end(req.method === 'HEAD' ? undefined : JSON.stringify(SERVER_INFO));
    }
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
  const members = room => [room.host, ...room.viewers.values()];
  const roster = room => {
    const msg = {type:'members', members:members(room).map(p => ({id:p.id, name:p.name, voice:!!p.voice}))};
    for (const p of members(room)) send(p, msg);
  };
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
    ws.on('message', async raw => {
      try {
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
          let media = null;
          if (msg.media != null) {
            const m=msg.media;
            if (m.protocol!=='abordage-1' || !Number.isInteger(m.width) || !Number.isInteger(m.height) || m.width<320 || m.width>3840 || m.height<180 || m.height>2160 || !Number.isInteger(m.fps) || m.fps<30 || m.fps>480 || !Number.isInteger(m.mbps) || m.mbps<5 || m.mbps>200) return send(ws,{type:'error',message:'Неверный профиль Абордажа.'});
            media={protocol:'abordage-1',width:m.width,height:m.height,fps:m.fps,mbps:m.mbps};
          }
          const id = randomBytes(12).toString('hex'), token = randomBytes(24).toString('hex');
          ws.host = true; ws.name = 'Капитан'; ws.room = id;
          const salt = randomBytes(16).toString('hex');
          const codeHash = createHash('sha256').update(salt + code).digest();
          rooms.set(id, {host:ws, token, salt, codeHash, attempts:0, attemptsSince:Date.now(), viewers:new Map(), media});
          clearTimeout(authTimer);
          const abordage = media ? await relay.register(rooms.get(id),ws) : undefined;
          if (ws.readyState!==WebSocket.OPEN) {rooms.delete(id);relay.remove(ws);return;}
          send(ws, {type:'created', abordage, id:ws.id, room:id, token, iceServers:ice(), maxViewers});
          roster(rooms.get(id));
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
          if (room.media && !msg.supports?.includes('abordage-1')) return send(ws,{type:'error',message:'Комната использует Абордаж. Откройте её в новом Windows или Android приложении.'});
          if (room.viewers.size >= maxViewers) return send(ws, {type:'error', message:'Комната заполнена.'});
          ws.room = msg.room; ws.name = crewName(room); room.viewers.set(ws.id, ws); clearTimeout(authTimer);
          const abordage = room.media ? await relay.register(room,ws) : undefined;
          if (ws.readyState!==WebSocket.OPEN) {room.viewers.delete(ws.id);relay.remove(ws);return;}
          send(ws, {type:'joined', abordage, id:ws.id, iceServers:ice()});
          send(room.host, {type:'viewer-joined', id:ws.id});
          roster(room);
        }
        return;
      }
      const room = rooms.get(ws.room);
      if (!room) return;
      if (msg.type === 'chat' && typeof msg.text === 'string') {
        const text = msg.text.trim();
        if (!text || text.length > 2000) return;
        if (Date.now() - (ws.lastChat || 0) < 300) return;
        ws.lastChat = Date.now();
        for (const p of members(room)) send(p, {type:'chat', from:ws.id, name:ws.name, text, at:Date.now()});
      }
      if (msg.type === 'abordage-nack' && !ws.host && room.media && Array.isArray(msg.blocks) && msg.blocks.length<=4 && msg.blocks.every(n=>Number.isInteger(n)&&n>0&&n<=0xffffffff)) {
        send(room.host,{type:'abordage-nack',blocks:msg.blocks});
      }
      if (msg.type === 'voice-state' && typeof msg.enabled === 'boolean') {
        ws.voice = msg.enabled; roster(room);
      }
      if (msg.type === 'voice-signal' && ws.voice && msg.data && typeof msg.data === 'object') {
        const target = members(room).find(p => p.id === msg.to && p !== ws && p.voice);
        if (target) send(target, {type:'voice-signal', from:ws.id, data:msg.data});
      }
      if (msg.type === 'signal' && msg.data && typeof msg.data === 'object') {
        const target = ws.host ? room.viewers.get(msg.to) : room.host;
        if (target) send(target, {type:'signal', from:ws.id, data:msg.data});
      }
      } catch {
        send(ws,{type:'error',message:'Не удалось подготовить медиасоединение.'});
        ws.close(1011,'Media setup failed');
      }
    });
    ws.on('close', () => {
      clearTimeout(authTimer);
      relay.remove(ws);
      const room = rooms.get(ws.room); if (!room) return;
      if (ws.host) {
        rooms.delete(ws.room);
        for (const viewer of room.viewers.values()) { send(viewer, {type:'ended'}); viewer.close(); }
      } else { room.viewers.delete(ws.id); send(room.host, {type:'viewer-left', id:ws.id}); roster(room); }
    });
  });
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) { if (!ws.alive) ws.terminate(); else { ws.alive = false; ws.ping(); } }
  }, 15000);
  heartbeat.unref();
  return {server, relay, ready:relay.ready, close: async () => {
    clearInterval(heartbeat);
    await relay.close();
    for (const ws of wss.clients) ws.terminate();
    await new Promise(resolve => wss.close(resolve));
    await new Promise(resolve => server.close(resolve));
  }};
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = createApp({...process.env,ABORDAGE_PORT:process.env.ABORDAGE_PORT || '3480'});
  app.server.listen(Number(process.env.PORT || 3000), '0.0.0.0', () => console.log('Пиратский трактир — порт', process.env.PORT || 3000));
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => app.close().then(() => process.exit(0)));
}
