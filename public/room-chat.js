export class RoomChat {
  constructor(send, onChange) { this.send = send; this.onChange = onChange; this.members = []; this.messages = []; this.peers = new Map(); this.enabled = false; this.muted = false; this.busy = false; this.generation = 0; this.error = ''; }
  post(text) { text = text.trim(); if (text && text.length <= 2000) this.send({type:'chat', text}); }
  async toggle() {
    if (this.busy) return;
    if (this.enabled) return this.leave();
    this.busy = true; this.error = ''; this.onChange(); const generation = this.generation;
    try {
      const mic = await navigator.mediaDevices.getUserMedia({video:false, audio:{echoCancellation:true, noiseSuppression:true, autoGainControl:true}});
      if (generation !== this.generation) { mic.getTracks().forEach(t => t.stop()); return; }
      this.mic = mic; this.enabled = true; this.muted = false; this.send({type:'voice-state', enabled:true});
    } catch (e) { this.error = `Микрофон недоступен: ${e.message}`; }
    finally { this.busy = false; this.onChange(); }
  }
  mute() { this.muted = !this.muted; this.mic?.getAudioTracks().forEach(t => { t.enabled = !this.muted; }); this.onChange(); }
  peer(id) {
    if (this.peers.has(id)) return this.peers.get(id);
    const pc = new RTCPeerConnection({iceServers:this.iceServers});
    const audio = document.createElement('audio'); audio.autoplay = true;
    audio.setAttribute('aria-label', 'Голос участника');
    const generation = this.generation;
    const peer = {pc, audio, candidates:[]}; this.peers.set(id, peer);
    pc.onicecandidate = e => { if (this.enabled && generation === this.generation && e.candidate) this.send({type:'voice-signal', to:id, data:{candidate:e.candidate}}); };
    pc.ontrack = e => { audio.srcObject ||= new MediaStream(); audio.srcObject.addTrack(e.track); audio.play().catch(() => { this.error = 'Браузер заблокировал звук голосового чата. Нажмите «Включить голоса».'; this.onChange(); }); };
    pc.onconnectionstatechange = () => { if (this.enabled && generation === this.generation && pc.connectionState === 'failed') { this.error = 'Не удалось подключить голос одного из участников. Проверьте TURN.'; this.onChange(); } };
    this.mic.getAudioTracks().forEach(t => pc.addTrack(t, this.mic));
    return peer;
  }
  async play() { for (const p of this.peers.values()) await p.audio.play(); this.error = ''; this.onChange(); }
  async handle(msg) {
    if (msg.type === 'chat') { this.messages.push(msg); if (this.messages.length > 100) this.messages.shift(); this.onChange(); }
    if (msg.type === 'members') {
      this.members = msg.members;
      const active = new Set(msg.members.filter(m => m.voice && m.id !== this.selfId).map(m => m.id));
      for (const [id, p] of this.peers) if (!this.enabled || !active.has(id)) { p.pc.close(); p.audio.srcObject = null; this.peers.delete(id); }
      if (this.enabled) for (const id of active) if (this.selfId < id && !this.peers.has(id)) {
        const {pc} = this.peer(id); await pc.setLocalDescription(await pc.createOffer());
        this.send({type:'voice-signal', to:id, data:{description:pc.localDescription}});
      }
      this.onChange();
    }
    if (msg.type === 'voice-signal' && this.enabled) {
      if (!this.members.some(m => m.id === msg.from && m.voice)) return;
      const p = this.peer(msg.from), {pc} = p;
      if (msg.data.description) {
        await pc.setRemoteDescription(msg.data.description);
        for (const c of p.candidates.splice(0)) await pc.addIceCandidate(c);
        if (msg.data.description.type === 'offer') { await pc.setLocalDescription(await pc.createAnswer()); this.send({type:'voice-signal', to:msg.from, data:{description:pc.localDescription}}); }
      }
      if (msg.data.candidate) { if (pc.remoteDescription) await pc.addIceCandidate(msg.data.candidate); else p.candidates.push(msg.data.candidate); }
    }
  }
  leave() { this.generation++; this.enabled = false; this.muted = false; this.send({type:'voice-state', enabled:false}); for (const p of this.peers.values()) { p.pc.close(); p.audio.srcObject = null; } this.peers.clear(); this.mic?.getTracks().forEach(t => t.stop()); this.mic = null; this.onChange(); }
  reset() { this.leave(); this.members = []; this.messages = []; this.error = ''; this.onChange(); }
}
