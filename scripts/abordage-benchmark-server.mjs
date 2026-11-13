import dgram from 'node:dgram';
import {createApp} from '../server.js';
const app=createApp({});await app.ready;
await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
const proxy=dgram.createSocket('udp4');let publisher=null;const removed=new Set();
const relayPort=app.relay.socket.address().port;
proxy.on('message',(bytes,remote)=>{
  if(remote.port===relayPort) {if(publisher) proxy.send(bytes,publisher.port,publisher.address);return;}
  publisher=remote;
  if(bytes[4]===3 && ((bytes[6]===0 && bytes.readUInt32BE(20)%10===0)||(bytes[6]===1 && bytes.readUInt32BE(20)%37===0))) {
    const token=bytes.readUInt32BE(20)+':'+bytes[6];
    if(!removed.has(token)) {removed.add(token);return;}
  }
  const send=()=>proxy.send(bytes,relayPort,'127.0.0.1');
  if(bytes[4]===3 && bytes[6]===1 && bytes.readUInt32BE(20)%7===0) setTimeout(send,2);else send();
});
await new Promise(r=>proxy.bind(0,'127.0.0.1',r));
setInterval(()=>process.stderr.write('ABR_STATS '+JSON.stringify({sent:app.relay.sent,dropped:app.relay.dropped})+'\n'),1000).unref();
console.log(JSON.stringify({port:app.server.address().port,proxyPort:proxy.address().port}));
for(const signal of ['SIGINT','SIGTERM']) process.on(signal,()=>{proxy.close();app.close().then(()=>process.exit(0));});
