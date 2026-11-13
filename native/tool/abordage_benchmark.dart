// Real H.264 encode -> UDP -> authenticated relay with loss -> FEC/decrypt -> decode.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:pirate_tavern/signaling.dart';
import 'package:pirate_tavern/abordage/transport.dart';

Future<void> main(List<String> arguments) async {
  final width = arguments.isNotEmpty ? int.parse(arguments[0]) : 320;
  final height = arguments.length > 1 ? int.parse(arguments[1]) : 180;
  final fps = arguments.length > 2 ? int.parse(arguments[2]) : 480;
  final mbps = arguments.length > 3 ? int.parse(arguments[3]) : 25;
  final root =
      Platform.environment['ABORDAGE_REPO'] ?? Directory.current.parent.path;
  final node = await Process.start('node', [
    '$root/scripts/abordage-benchmark-server.mjs',
  ]);
  Map<String, dynamic> relayStats = {};
  node.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    if (line.startsWith('ABR_STATS ')) {
      relayStats = Map<String, dynamic>.from(
        jsonDecode(line.substring(10)) as Map,
      );
    } else {
      stderr.writeln(line);
    }
  });
  await node.stdin.close();
  final first = await node.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  final server = jsonDecode(first) as Map<String, dynamic>;
  final origin = Uri.parse('http://127.0.0.1:${server['port']}');
  final host = Signaling(),
      viewer = Signaling(),
      send = AbordageTransport(),
      receive = AbordageTransport();
  Process? encoder, decoder;
  final failures = <String>[], subscriptions = <StreamSubscription<String>>[];
  final room = Completer<Map<String, dynamic>>(),
      joined = Completer<Map<String, dynamic>>();
  Map<String, dynamic> senderStats = {}, receiverStats = {};
  void failure(String value) {
    failures.add(value);
    stderr.writeln(value);
  }

  try {
    await host.connect(
      origin: origin,
      firstMessage: {
        'type': 'create',
        'roomCode': 'BENCH',
        'media': {
          'protocol': 'abordage-1',
          'width': width,
          'height': height,
          'fps': fps,
          'mbps': mbps,
        },
      },
      onMessage: (m) async {
        if (m['type'] == 'created') room.complete(m);
        if (m['type'] == 'abordage-nack') {
          send.retransmit(List<int>.from(m['blocks'] as List));
        }
      },
      onFailure: failure,
    );
    final created = await room.future.timeout(const Duration(seconds: 10));
    final decodePort = await reserveLoopbackPort();
    decoder = await Process.start('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-fflags',
      '+nobuffer',
      '-flags',
      'low_delay',
      '-probesize',
      '32768',
      '-analyzeduration',
      '0',
      '-i',
      'udp://127.0.0.1:$decodePort?localaddr=127.0.0.1&fifo_size=8192&overrun_nonfatal=1&buffer_size=2097152',
      '-an',
      '-vf',
      'crop=256:8:0:0,format=gray',
      '-fps_mode',
      'passthrough',
      '-flush_packets',
      '1',
      '-f',
      'rawvideo',
      'pipe:1',
    ]);
    await decoder.stdin.close();
    final clock = Stopwatch();
    var decoded = 0, encoded = 0;
    final latencies = <double>[];
    var raw = Uint8List(0), invalidStamps = 0;
    var measuring = false;
    final pixelSubscription = decoder.stdout.listen((chunk) {
      final bytes = Uint8List(raw.length + chunk.length)
        ..setAll(0, raw)
        ..setAll(raw.length, chunk);
      var offset = 0;
      while (bytes.length - offset >= 2048) {
        var stamp = 0;
        for (var bit = 0; bit < 32; bit++) {
          if (bytes[offset + 4 * 256 + bit * 8 + 4] > 128) stamp |= 1 << bit;
        }
        decoded++;
        if (measuring) {
          final ms =
              ((DateTime.now().millisecondsSinceEpoch & 0xffffffff) - stamp) &
              0xffffffff;
          if (ms < 10000) {
            latencies.add(ms.toDouble());
          } else {
            invalidStamps++;
          }
        }
        offset += 2048;
      }
      raw = Uint8List.sublistView(bytes, offset);
    });
    final decoderErrors = <String>[];
    subscriptions.add(
      decoder.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (measuring && decoderErrors.length < 12) {
              decoderErrors.add(line);
            }
          }),
    );
    final publisher = Map<String, dynamic>.from(created['abordage'] as Map)
      ..['port'] = server['proxyPort'];
    final encodePort = await send.start(
      publisher,
      host: '127.0.0.1',
      publish: true,
      onStats: (m) => senderStats = m,
      onFailure: failure,
    );
    clock.start();
    encoder = await Process.start('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-re',
      '-readrate_initial_burst',
      '0.001',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=${width}x$height:rate=$fps',
      '-filter_complex',
      "[0:v]noise=alls=20:allf=t[base];nullsrc=s=32x2:r=$fps,geq=lum='32+180*mod(floor(time(0)*1000/pow(2,X)),2)':cb=128:cr=128,scale=256:8:flags=neighbor[stamp];[base][stamp]overlay=0:0:shortest=1",
      '-an',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-tune',
      'zerolatency',
      '-threads',
      '2',
      '-b:v',
      '${mbps}M',
      '-minrate',
      '${mbps}M',
      '-maxrate',
      '${mbps}M',
      '-bufsize',
      '${mbps * 1000000 ~/ 20}',
      '-g',
      '${fps ~/ 4}',
      '-bf',
      '0',
      '-x264-params',
      'nal-hrd=cbr:force-cfr=1',
      '-fps_mode',
      'passthrough',
      '-flags:v',
      '+global_header',
      '-bsf:v',
      'dump_extra=freq=keyframe',
      '-progress',
      'pipe:1',
      '-stats_period',
      '1',
      '-mpegts_flags',
      '+resend_headers+pat_pmt_at_frames',
      '-muxdelay',
      '0',
      '-muxpreload',
      '0',
      '-flush_packets',
      '1',
      '-f',
      'mpegts',
      'udp://127.0.0.1:$encodePort?pkt_size=1128&buffer_size=2097152&bitrate=${((mbps * 1.25 + 1) * 1000000).round()}&burst_bits=18048',
    ]);
    await encoder.stdin.close();
    subscriptions.add(
      encoder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('frame=')) {
              encoded = int.tryParse(line.substring(6).trim()) ?? encoded;
            }
          }),
    );
    subscriptions.add(
      encoder.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(stderr.writeln),
    );
    // Join after the encoder is running: exercises periodic SPS/PPS/IDR delivery.
    await Future<void>.delayed(const Duration(seconds: 2));
    await viewer.connect(
      origin: origin,
      firstMessage: {
        'type': 'join',
        'room': created['room'],
        'token': created['token'],
        'roomCode': 'BENCH',
        'supports': ['abordage-1'],
      },
      onMessage: (m) async {
        if (m['type'] == 'joined') joined.complete(m);
      },
      onFailure: failure,
    );
    final watched = await joined.future.timeout(const Duration(seconds: 10));
    await receive.start(
      Map<String, dynamic>.from(watched['abordage'] as Map),
      host: '127.0.0.1',
      publish: false,
      playbackPort: decodePort,
      onStats: (m) => receiverStats = m,
      onFailure: failure,
      onNack: (blocks) =>
          viewer.send({'type': 'abordage-nack', 'blocks': blocks}),
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    measuring = true;
    final beforeFrames = decoded,
        beforeBytes = receiverStats['bytes'] as int? ?? 0,
        measure = Stopwatch()..start();
    final beforeMicros = receiverStats['micros'] as int? ?? 0;
    final beforeLost = receiverStats['lost'] as int? ?? 0,
        beforeDropped = senderStats['dropped'] as int? ?? 0;
    await Future<void>.delayed(const Duration(seconds: 6));
    measuring = false;
    final decodedFps =
        (decoded - beforeFrames) / measure.elapsedMicroseconds * 1000000;
    final receivedMbps =
        ((receiverStats['bytes'] as int? ?? 0) - beforeBytes) *
        8 /
        ((receiverStats['micros'] as int? ?? 0) - beforeMicros);
    latencies.sort();
    await pixelSubscription.cancel();
    final result = {
      'relay': relayStats,
      'target': '${width}x$height@$fps',
      'steadyLostBlocks': (receiverStats['lost'] as int? ?? 0) - beforeLost,
      'steadySenderDrops':
          (senderStats['dropped'] as int? ?? 0) - beforeDropped,
      'decodedFPS': decodedFps,
      'receivedMbps': receivedMbps,
      'encodedFrames': encoded,
      'decodedFrames': decoded,
      'invalidTimestampFrames': invalidStamps,
      'latencyP50ms': latencies.isEmpty
          ? null
          : latencies[latencies.length ~/ 2],
      'latencyP95ms': latencies.isEmpty
          ? null
          : latencies[(latencies.length * 0.95).floor()],
      'sender': senderStats,
      'receiver': receiverStats,
      'errors': decoderErrors,
    };
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
    if (failures.isNotEmpty ||
        decodedFps < fps * 0.8 ||
        receivedMbps < mbps * 0.6 ||
        (receiverStats['recovered'] as int? ?? 0) == 0 ||
        decoderErrors.isNotEmpty ||
        (receiverStats['lost'] as int? ?? 0) > beforeLost ||
        (senderStats['dropped'] as int? ?? 0) > beforeDropped ||
        latencies.isEmpty ||
        invalidStamps > latencies.length ~/ 100 ||
        latencies[latencies.length ~/ 2] > 250) {
      throw StateError('Abordage end-to-end regression failed');
    }
  } finally {
    encoder?.kill(ProcessSignal.sigkill);
    decoder?.kill(ProcessSignal.sigkill);
    await send.close();
    await receive.close();
    await viewer.close();
    await host.close();
    node.kill();
    if (encoder != null) await encoder.exitCode;
    if (decoder != null) await decoder.exitCode;
    await node.exitCode;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}
