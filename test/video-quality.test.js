import {test} from 'node:test';
import assert from 'node:assert/strict';
import {videoQualitySdp, videoBudget} from '../public/video-quality.js';
const sdp = 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\nb=AS:64\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 97 102\r\nc=IN IP4 0.0.0.0\r\nb=AS:2500\r\na=rtpmap:96 VP8/90000\r\na=rtpmap:97 rtx/90000\r\na=fmtp:97 apt=96\r\na=rtpmap:102 H264/90000\r\na=fmtp:102 packetization-mode=1;profile-level-id=42e01f;x-google-max-bitrate=2500\r\n';
test('video budget replaces defaults in offer and answer and preserves audio/RTX/H264 compatibility', () => {
 const result = videoQualitySdp(sdp,{mbps:50,fps:144});
 assert.ok(result.includes('b=TIAS:50000000\r\n'));
 assert.ok(result.includes('x-google-start-bitrate=40000'));
 assert.ok(!result.includes('=2500'));
 assert.deepEqual(videoBudget(result),{mbps:50,fps:144});
 assert.equal(result.split('m=video')[0],sdp.split('m=video')[0]);
 assert.ok(result.includes('a=fmtp:97 apt=96\r\n'));
 assert.ok(result.includes('profile-level-id=42e01f'));
 assert.equal(videoQualitySdp(result,{mbps:50,fps:144}),result);
 assert.equal(videoBudget(sdp.split('m=video')[0]),null);
 assert.throws(() => videoQualitySdp(sdp,{mbps:0,fps:144}));
});
