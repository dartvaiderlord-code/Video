import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/protocol.dart';
import 'package:pirate_tavern/video_quality.dart';

void main() {
  test('bidirectional video budget preserves H264 profile, RTX and audio', () {
    const audio =
        'v=0\r\na=ice-pwd:random=\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\nb=AS:64\r\na=rtpmap:111 opus/48000/2\r\n';
    const input =
        '${audio}m=video 9 UDP/TLS/RTP/SAVPF 96 97 102\r\nc=IN IP4 0.0.0.0\r\nb=AS:2500\r\na=rtpmap:96 VP8/90000\r\na=rtpmap:97 rtx/90000\r\na=fmtp:97 apt=96\r\na=rtpmap:102 H264/90000\r\na=fmtp:102 packetization-mode=1;profile-level-id=42e01f;x-google-max-bitrate=2500\r\n';
    const profile = CaptureProfile(mbps: 50, fps: 144);
    final result = videoQualitySdp(input, profile);
    expect(result.startsWith(audio), true);
    expect(result, contains('b=TIAS:50000000\r\n'));
    expect(result, contains('x-google-min-bitrate=30000'));
    expect(result, contains('x-google-start-bitrate=40000'));
    expect(result, contains('a=fmtp:97 apt=96\r\n'));
    expect(result, contains('profile-level-id=42e01f'));
    expect(result, isNot(contains('=2500')));
    expect(videoBudget(result)!.mbps, 50);
    expect(videoBudget(result)!.fps, 144);
    expect(videoQualitySdp(result, profile), result);
    expect(videoBudget(audio), null);
  });
}
