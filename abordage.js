// Abordage/1: authenticated UDP relay. Media ciphertext stays opaque here.
import dgram from 'node:dgram';
import {createHmac, randomBytes, timingSafeEqual} from 'node:crypto';

export const ABORDAGE = Object.freeze({name:'abordage-1', header:32, mac:16, shard:1136, maxShards:8});
export class ReplayWindow {
  high = -1; bits = 0n;
  accept(seq) {
    if (seq > this.high) {
      const jump = seq - this.high;
      this.bits = jump >= 256 ? 1n : ((this.bits << BigInt(jump)) | 1n) & ((1n << 256n) - 1n);
      this.high = seq; return true;
    }
    const delta = this.high - seq;
    if (delta >= 256 || (this.bits & (1n << BigInt(delta)))) return false;
    this.bits |= 1n << BigInt(delta); return true;
  }
}
export function packetMac(bytes, key) {return createHmac('sha256',key).update(bytes).digest().subarray(0,16);}
export function readPacket(bytes, key) {
  if (bytes.length < 48 || bytes.length > 1184 || bytes.toString('ascii',0,4) !== 'ABR1') return null;
  const body = bytes.subarray(0,-16);
  if (!timingSafeEqual(packetMac(body,key), bytes.subarray(-16))) return null;
  const kind=bytes[4], index=bytes[6], count=bytes[7], length=bytes.readUInt32BE(24);
  if (bytes[5] !== 0 || ![1,3,4].includes(kind)) return null;
  if (kind === 3) {
    if (!count || count > 8 || index > count || length < 17 || length > count*1136 || Math.ceil(length/1136)!==count) return null;
    const expected = index===count ? 1136 : Math.min(1136,length-index*1136);
    if (body.length !== 32+expected) return null;
  } else if (body.length !== 32 || index || count || length) return null;
  return {kind, seq:bytes.readUInt32BE(16)};
}
export class AbordageRelay {
  peers = new Map(); sent = 0; dropped = 0;
  constructor({port=0, publicPort, host, bind='0.0.0.0'}={}) {
    this.publicPort=publicPort;this.host=host;
    this.socket=dgram.createSocket('udp4');
    this.ready=new Promise((resolve,reject)=>{
      this.socket.once('error',reject);
      this.socket.bind(port,bind,()=>{
        this.socket.removeListener('error',reject);
        try {this.socket.setRecvBufferSize(4*1024*1024);this.socket.setSendBufferSize(4*1024*1024);} catch { /* Kernel may cap buffers. */ }
        resolve();
      });
    });
    // Binding failure propagates through ready. Do not crash on later ICMP errors.
    this.socket.on('error',()=>{});
    this.socket.on('message',(bytes,remote)=>this.receive(bytes,remote));
  }
  async register(room, ws) {
    await this.ready;
    room.abordage ??= {key:randomBytes(32),prefix:randomBytes(20)};
    const id=randomBytes(8).toString('hex'), key=randomBytes(32);
    const peer={id,key,room,ws,replay:new ReplayWindow(),endpoint:null,lastSeen:0,bytes:0,since:Date.now()};
    this.peers.set(id,peer);ws.abordagePeer=id;
    return {protocol:ABORDAGE.name,id,key:key.toString('hex'),cipherKey:room.abordage.key.toString('hex'),noncePrefix:room.abordage.prefix.toString('hex'),port:this.publicPort || this.socket.address().port,...(this.host ? {host:this.host} : {}),profile:room.media};
  }
  receive(bytes, remote) {
    if (bytes.length<48 || bytes.length>1184) return;
    const peer=this.peers.get(bytes.subarray(8,16).toString('hex'));
    if (!peer || peer.ws.readyState!==1) return;
    const packet=readPacket(bytes,peer.key);
    if (!packet || !peer.replay.accept(packet.seq)) return;
    const now=Date.now();
    if (packet.kind===1 || packet.kind===4) {
      // Only a fresh, authenticated registration may change the NAT endpoint.
      peer.endpoint=remote;peer.lastSeen=now;
      const ack=Buffer.from(bytes);ack[4]=packet.kind===1 ? 2 : 5;
      packetMac(ack.subarray(0,-16),peer.key).copy(ack,ack.length-16);
      this.socket.send(ack,remote.port,remote.address,()=>{});return;
    }
    if (!peer.ws.host || !peer.endpoint || peer.endpoint.address!==remote.address || peer.endpoint.port!==remote.port || now-peer.lastSeen>15000) return;
    if (now-peer.since>=1000) {peer.bytes=0;peer.since=now;}
    // Fixed bitrate is intentional, but one publisher cannot exhaust the relay.
    peer.bytes+=bytes.length;
    const cap=(peer.room.media.mbps+5)*1_000_000/8*1.5;
    if (peer.bytes>cap || this.socket.getSendQueueSize()>2*1024*1024) {this.dropped++;return;}
    for (const viewer of peer.room.viewers.values()) {
      const target=this.peers.get(viewer.abordagePeer);
      if (!target?.endpoint || now-target.lastSeen>15000 || target.ws.readyState!==1) continue;
      const out=Buffer.from(bytes);
      Buffer.from(target.id,'hex').copy(out,8);
      packetMac(out.subarray(0,-16),target.key).copy(out,out.length-16);
      this.socket.send(out,target.endpoint.port,target.endpoint.address,()=>{});this.sent++;
    }
  }
  remove(ws) {
    const peer=this.peers.get(ws.abordagePeer);
    if (peer) {peer.key.fill(0);this.peers.delete(peer.id);}
  }
  async close() {
    try {await this.ready;await new Promise(r=>this.socket.close(r));} catch { /* Failed bind already closed. */ }
    this.peers.clear();
  }
}
