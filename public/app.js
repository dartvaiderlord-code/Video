const $ = id => document.getElementById(id);
const video = $('video');
const params = new URLSearchParams(location.hash.slice(1));
const isViewer = params.has('room');
let socket, stream, iceServers, active = false, intentional = false;
const peers = new Map();
let statTimer;
let captureTimer;
let captureRequest;
const status = message => { $('status').textContent = message; };
const send = msg => { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg)); };
if (isViewer) {
  $('title').textContent = 'Вас пригласили на просмотр';
  $('host-options').hidden = true; $('viewer-options').hidden = false; $('start').hidden = true; $('join').hidden = false;
  $('count').hidden = true; status('Введите код от капитана и присоединяйтесь к трансляции.');
}
function cleanup(message) {
  intentional = true; active = false;
  socket?.close(); socket = null;
  for (const {pc} of peers.values()) pc.close(); peers.clear();
  stream?.getTracks().forEach(track => track.stop()); stream = null;
  clearInterval(statTimer); clearInterval(captureTimer);
  $('capture-stats').hidden = true;
  $('viewer-options').hidden = !isViewer; video.srcObject = null;
  $('stage').hidden = true; $('invite').hidden = true; $('stop').hidden = true;
  $('start').hidden = isViewer; $('start').disabled = false;
  $('join').hidden = !isViewer; $('join').disabled = false;
  $('host-options').hidden = isViewer;
  if (!isViewer) $('count').textContent = 'До 6 зрителей';
  if (message) status(message);
}
function makePeer(id) {
  const pc = new RTCPeerConnection({iceServers});
  const peer = {pc, candidates:[]}; peers.set(id, peer);
  pc.onicecandidate = e => { if (e.candidate) send({type:'signal', to:id, data:{candidate:e.candidate}}); };
  pc.onconnectionstatechange = () => {
    if (pc.connectionState === 'connected') status(isViewer ? 'Вы смотрите прямую трансляцию.' : `Трансляция идёт · зрителей: ${peers.size}`);
    if (pc.connectionState === 'failed') status('Не удалось передать видео. Переподключитесь; для сложного NAT нужен настроенный TURN.');
    if (pc.connectionState === 'disconnected') status('Связь прервалась, ожидаем восстановления…');
  };
  if (isViewer) pc.ontrack = e => {
    if (!video.srcObject) video.srcObject = new MediaStream();
    if (!video.srcObject.getTracks().some(t => t.id === e.track.id)) video.srcObject.addTrack(e.track);
    $('stage').hidden = false;
    video.play().catch(() => { $('play').hidden = false; });
  };
  return peer;
}
async function handle(msg) {
  if (msg.type === 'error') { cleanup(msg.message); return; }
  if (msg.type === 'created') {
    iceServers = msg.iceServers; active = true;
    $('link').value = `${location.origin}/#room=${msg.room}&token=${msg.token}`;
    $('invite').hidden = false; $('stop').hidden = false; $('start').hidden = true;
    $('host-options').hidden = true; $('count').textContent = `0 / ${msg.maxViewers} зрителей`;
    status(`Трансляция готова. ${stream.getAudioTracks().length ? 'Звук передаётся.' : 'Звук не выбран — передаётся только видео.'}`);
  }
  if (msg.type === 'joined') {
    iceServers = msg.iceServers; active = true; makePeer('host');
    $('join').hidden = true; $('viewer-options').hidden = true; $('stop').hidden = false;
    $('stop').textContent = 'Отключиться'; status('Подключаем видео…');
    startStats();
  }
  if (msg.type === 'viewer-joined') {
    const {pc} = makePeer(msg.id);
    for (const track of stream.getTracks()) pc.addTrack(track, stream);
    await pc.setLocalDescription(await pc.createOffer());
    for (const sender of pc.getSenders()) {
      if (sender.track.kind !== 'video') continue;
      const p = sender.getParameters(); p.encodings ||= [{}];
      if (!p.encodings.length) p.encodings.push({});
      p.encodings[0].maxBitrate = captureRequest.bitrate * 1000000;
      p.encodings[0].maxFramerate = captureRequest.fps;
      p.degradationPreference = 'maintain-framerate';
      await sender.setParameters(p).catch(() => {});
    }
    send({type:'signal', to:msg.id, data:{description:pc.localDescription}});
    $('count').textContent = `${peers.size} зрителей`;
  }
  if (msg.type === 'viewer-left') {
    peers.get(msg.id)?.pc.close(); peers.delete(msg.id);
    $('count').textContent = `${peers.size} зрителей`;
  }
  if (msg.type === 'signal') {
    const peer = peers.get(isViewer ? 'host' : msg.from); if (!peer) return;
    const {pc} = peer, data = msg.data;
    if (data.description) {
      await pc.setRemoteDescription(data.description);
      for (const c of peer.candidates.splice(0)) await pc.addIceCandidate(c);
      if (data.description.type === 'offer' && isViewer) {
        await pc.setLocalDescription(await pc.createAnswer());
        send({type:'signal', data:{description:pc.localDescription}});
      }
    }
    if (data.candidate) {
      if (pc.remoteDescription) await pc.addIceCandidate(data.candidate);
      else peer.candidates.push(data.candidate);
    }
  }
  if (msg.type === 'ended') cleanup('Автор завершил трансляцию. Для нового эфира нужна новая ссылка.');
}
function connect(firstMessage) {
  intentional = false;
  const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`);
  socket = ws;
  const timeout = setTimeout(() => { if (socket === ws && !active) cleanup('Сервер не отвечает. Попробуйте подключиться ещё раз.'); }, 15000);
  ws.onopen = () => send(firstMessage);
  let chain = Promise.resolve();
  ws.onmessage = e => { chain = chain.then(() => socket === ws && handle(JSON.parse(e.data))).catch(() => cleanup('Ошибка соединения. Попробуйте подключиться заново.')); };
  ws.onclose = () => { clearTimeout(timeout); if (socket !== ws) return; if (!intentional) cleanup('Соединение с сервером потеряно. Подключитесь заново.'); };
  ws.onerror = () => { clearTimeout(timeout); if (socket !== ws) return; cleanup('Не удалось подключиться к серверу. Проверьте HTTPS и WebSocket на прокси.'); };
}
$('start').onclick = async () => {
  if (!navigator.mediaDevices?.getDisplayMedia) return status('Для передачи экрана откройте сайт по HTTPS в Chrome/Edge на компьютере.');
  const roomCode = $('room-code').value.trim();
  if (roomCode.length < 4 || roomCode.length > 64) return status('Придумайте код комнаты: от 4 до 64 символов.');
  $('start').disabled = true;
  try {
    captureRequest = {height:Number($('quality').value), fps:Number($('fps').value), bitrate:Number($('bitrate').value)};
    stream = await navigator.mediaDevices.getDisplayMedia({
      video:{height:{ideal:captureRequest.height}, frameRate:{ideal:captureRequest.fps, max:captureRequest.fps}},
      audio:true, systemAudio:'include', selfBrowserSurface:'exclude', surfaceSwitching:'include'
    });
    captureTimer = setInterval(updateCaptureStats, 2000); updateCaptureStats();
    stream.getVideoTracks()[0].contentHint = 'motion';
    stream.getVideoTracks()[0].onended = () => cleanup('Трансляция завершена.');
    video.muted = true; video.srcObject = stream; $('stage').hidden = false;
    video.play().catch(() => {});
    status('Создаём комнату…'); connect({type:'create', roomCode});
  } catch (e) { cleanup(e.name === 'NotAllowedError' ? 'Выбор экрана отменён или доступ не разрешён.' : 'Не удалось захватить экран: ' + e.message); }
};
$('join').onclick = () => {
  if (!window.RTCPeerConnection) return status('Браузер не поддерживает WebRTC.');
  const roomCode = $('join-code').value.trim();
  if (roomCode.length < 4 || roomCode.length > 64) return status('Введите код комнаты от капитана: от 4 до 64 символов.');
  $('join').disabled = true; video.muted = false;
  connect({type:'join', room:params.get('room'), token:params.get('token'), roomCode});
};
$('stop').onclick = () => cleanup(isViewer ? 'Вы отключились.' : 'Трансляция завершена.');
$('play').onclick = () => video.play().then(() => { $('play').hidden = true; }).catch(() => status('Нажмите воспроизведение на плеере.'));
$('copy').onclick = async () => {
  try { await navigator.clipboard.writeText($('link').value); $('copy').textContent = 'Скопировано'; setTimeout(() => { $('copy').textContent = 'Копировать'; }, 1800); }
  catch { $('link').select(); status('Скопируйте выделенную ссылку вручную.'); }
};
function updateCaptureStats() {
  const track = stream?.getVideoTracks()[0]; if (!track) return;
  const settings = track.getSettings();
  $('capture-stats').hidden = false;
  $('capture-stats').textContent = `Захват: ${settings.width || '—'}×${settings.height || '—'} · ${Math.round(settings.frameRate || 0)} FPS. Запрошено: ${captureRequest.height}p / ${captureRequest.fps} FPS · лимит ${captureRequest.bitrate} Мбит/с на зрителя. Фактическая передача может быть ниже.`;
}
function startStats() {
  statTimer = setInterval(async () => {
    const pc = peers.get('host')?.pc; if (!pc || pc.connectionState !== 'connected') return;
    const stats = await pc.getStats(); let transport, inbound;
    stats.forEach(s => { if (s.type === 'transport') transport = s; if (s.type === 'inbound-rtp' && s.kind === 'video') inbound = s; });
    const pair = stats.get(transport?.selectedCandidatePairId);
    const local = stats.get(pair?.localCandidateId), remote = stats.get(pair?.remoteCandidateId);
    const relay = local?.candidateType === 'relay' || remote?.candidateType === 'relay';
    $('stats').textContent = `${relay ? 'Через TURN' : 'Прямое соединение'}${inbound ? ` · ${inbound.frameWidth || '—'}×${inbound.frameHeight || '—'} · ${inbound.framesPerSecond || 0} кадров/с` : ''}${pair?.currentRoundTripTime != null ? ` · RTT ${Math.round(pair.currentRoundTripTime * 1000)} мс` : ''}`;
  }, 2000);
}
window.addEventListener('pagehide', () => cleanup());
