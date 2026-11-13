// Real production transports and relay for probe_abordage_playback.py.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:pirate_tavern/signaling.dart';
import 'package:pirate_tavern/abordage/transport.dart';

Future<void> main(List<String> args) async {
  final root =
      Platform.environment['ABORDAGE_REPO'] ?? Directory.current.parent.path;
  final node = await Process.start('node', [
    '$root/scripts/abordage-benchmark-server.mjs',
  ]);
  node.stderr.transform(utf8.decoder).listen(stderr.write);
  final line = await node.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  final server = jsonDecode(line) as Map<String, dynamic>;
  final origin = Uri.parse('http://127.0.0.1:${server['port']}');
  final host = Signaling(), viewer = Signaling();
  final send = AbordageTransport(), receive = AbordageTransport();
  final room = Completer<Map<String, dynamic>>(),
      joined = Completer<Map<String, dynamic>>();
  final stopped = Completer<void>();
  void fail(String message) {
    stderr.writeln(message);
    exitCode = 1;
    if (!stopped.isCompleted) stopped.complete();
  }

  void stats(String role, Map<String, dynamic> value) {
    stdout.writeln(jsonEncode({'role': role, ...value}));
  }

  final input = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((_) {
        if (!stopped.isCompleted) stopped.complete();
      });
  try {
    await host.connect(
      origin: origin,
      firstMessage: {
        'type': 'create',
        'roomCode': 'PROBE',
        'media': {
          'protocol': 'abordage-1',
          'width': 640,
          'height': 360,
          'fps': 240,
          'mbps': 50,
        },
      },
      onMessage: (m) async {
        if (m['type'] == 'created') room.complete(m);
        if (m['type'] == 'abordage-nack') {
          send.retransmit(List<int>.from(m['blocks'] as List));
        }
      },
      onFailure: fail,
    );
    final created = await room.future.timeout(const Duration(seconds: 10));
    final publisher = Map<String, dynamic>.from(created['abordage'] as Map)
      ..['port'] = server['proxyPort'];
    final port = await send.start(
      publisher,
      host: '127.0.0.1',
      publish: true,
      onStats: (m) => stats('sender', m),
      onFailure: fail,
    );
    stdout.writeln(jsonEncode({'inputPort': port}));
    // Exercise joining a stream that is already running.
    await Future<void>.delayed(const Duration(seconds: 2));
    await viewer.connect(
      origin: origin,
      firstMessage: {
        'type': 'join',
        'room': created['room'],
        'token': created['token'],
        'roomCode': 'PROBE',
        'supports': ['abordage-1'],
      },
      onMessage: (m) async {
        if (m['type'] == 'joined') joined.complete(m);
      },
      onFailure: fail,
    );
    final watched = await joined.future.timeout(const Duration(seconds: 10));
    await receive.start(
      Map<String, dynamic>.from(watched['abordage'] as Map),
      host: '127.0.0.1',
      publish: false,
      playbackPort: int.parse(args.single),
      onStats: (m) => stats('receiver', m),
      onFailure: fail,
      onNack: (blocks) =>
          viewer.send({'type': 'abordage-nack', 'blocks': blocks}),
    );
    await stopped.future.timeout(const Duration(seconds: 30));
  } finally {
    await send.close();
    await receive.close();
    await viewer.close();
    await host.close();
    await input.cancel();
    node.kill();
    await node.exitCode;
  }
}
