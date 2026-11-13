import {test} from 'node:test';
import assert from 'node:assert/strict';
import dgram from 'node:dgram';
import {WebSocket} from 'ws';
import {createApp} from '../server.js';
import {packetMac,ReplayWindow} from '../abordage.js';
function packet(c,kind,seq,{block=0,count=0,index=0,payload=Buffer.alloc(0),length=0}={}) {
  const bytes=Buffer.alloc(48+payload.length);bytes.write('ABR1');bytes[4]=kind;bytes[6]=index;bytes[7]=count;
  Buffer.from(c.id,'hex').copy(bytes,8);bytes.writeUInt32BE(seq,16);bytes.writeUInt32BE(block,20);bytes.writeUInt32BE(length,24);
  payload.copy(bytes,32);packetMac(bytes.subarray(0,-16),Buffer.from(c.key,'hex')).copy(bytes,bytes.length-16);return bytes;
}
function queue(emitter,event) {
  const values=[],waiting=[];
  emitter.on(event,value=>{if(waiting.length) waiting.shift()(value);else values.push(value);});
  return async()=>values.length?values.shift():new Promise(r=>waiting.push(r));
}
test('Abordage authenticates UDP, routes only the publisher and prevents endpoint hijack/replay', {timeout:10000},async t=>{
  const app=createApp({STUN_URLS:'stun:example.test'});await app.ready;
  await new Promise(r=>app.server.listen(0,'127.0.0.1',r));t.after(()=>app.close());
  const origin=`http://127.0.0.1:${app.server.address().port}`;
  async function client(first) {
    const ws=new WebSocket(origin.replace('http','ws')+'/ws',{origin});
    const raw=queue(ws,'message');await new Promise(r=>ws.once('open',r));ws.send(JSON.stringify(first));
    const next=async type=>{for(;;){const m=JSON.parse(await raw());if(m.type==='error') throw Error(m.message);if(m.type===type) return m;}};
    return {ws,next};
  }
  const host=await client({type:'create',roomCode:'CREW',media:{protocol:'abordage-1',width:1920,height:1080,fps:120,mbps:50}});
  const room=await host.next('created');assert.equal(room.abordage.protocol,'abordage-1');
  assert.equal(room.abordage.noncePrefix.length,40);
  const viewer=await client({type:'join',room:room.room,token:room.token,roomCode:'CREW',supports:['abordage-1']});
  const joined=await viewer.next('joined');assert.equal(joined.abordage.cipherKey,room.abordage.cipherKey);
  assert.notEqual(joined.abordage.key,room.abordage.key);
  async function udp(c) {
    const socket=dgram.createSocket('udp4'),next=queue(socket,'message');t.after(()=>socket.close());
    await new Promise(r=>socket.bind(0,'127.0.0.1',r));
    const send=bytes=>socket.send(bytes,c.port,'127.0.0.1');send(packet(c,1,1));
    assert.equal((await next())[4],2);return {socket,send,next};
  }
  const h=await udp(room.abordage),v=await udp(joined.abordage);
  viewer.ws.send(JSON.stringify({type:'abordage-nack',blocks:[1,3],to:'outside'}));
  assert.deepEqual((await host.next('abordage-nack')).blocks,[1,3]);
  const body=Buffer.alloc(900,42),media=packet(room.abordage,3,2,{block:1,count:1,length:900,payload:body});
  h.send(media);const relayed=await v.next();
  assert.deepEqual(relayed.subarray(32,-16),body);
  assert.equal(relayed.subarray(8,16).toString('hex'),joined.abordage.id);
  assert.deepEqual(relayed.subarray(-16),packetMac(relayed.subarray(0,-16),Buffer.from(joined.abordage.key,'hex')));
  const rogue=dgram.createSocket('udp4');t.after(()=>rogue.close());await new Promise(r=>rogue.bind(0,'127.0.0.1',r));
  rogue.send(packet(room.abordage,1,1),room.abordage.port,'127.0.0.1'); // replay cannot rebind
  h.send(media); // duplicate media cannot be forwarded
  v.send(packet(joined.abordage,3,2,{block:2,count:1,length:900,payload:body})); // viewer cannot publish
  const corrupt=packet(room.abordage,3,3,{block:3,count:1,length:900,payload:body});corrupt[40]^=1;h.send(corrupt);
  await new Promise(r=>setTimeout(r,30));assert.equal(app.relay.sent,1);
  assert.equal(app.relay.peers.get(room.abordage.id).endpoint.port,h.socket.address().port);
  h.send(packet(room.abordage,3,4,{block:4,count:1,length:900,payload:body}));
  assert.equal((await v.next()).readUInt32BE(20),4);
  viewer.ws.close();await new Promise(r=>viewer.ws.once('close',r));
  assert.equal(app.relay.peers.has(joined.abordage.id),false);
});
test('Abordage replay window handles late packets, duplicates and large jumps',()=>{
  const replay=new ReplayWindow();assert.equal(replay.accept(1000),true);assert.equal(replay.accept(999),true);
  assert.equal(replay.accept(999),false);assert.equal(replay.accept(700),false);assert.equal(replay.accept(100000),true);assert.equal(replay.accept(1000),false);
});
