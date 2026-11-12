import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/protocol.dart';
import 'package:pirate_tavern/signaling.dart';

void main() {
  test('invitation preserves token fragment and excludes the chosen code', () {
    final link =
        'https://tavern.example:8443/#room=${'a' * 24}&token=${'b' * 48}';
    final invite = RoomInvite.parse(link);
    expect(invite.server.origin, 'https://tavern.example:8443');
    expect(invite.link, link);
    expect(invite.join(' GOIDA ')['roomCode'], 'GOIDA');
    expect(invite.link.contains('GOIDA'), false);
  });
  test(
    'rejects insecure URLs, userinfo, foreign paths and missing room tokens',
    () {
      for (final value in [
        'http://example.com',
        'https://user:password@example.com',
        'https://example.com/another-app',
        'https://example.com/?token=secret',
      ]) {
        expect(() => serverOrigin(value), throwsFormatException);
      }
      expect(
        () => RoomInvite.parse('https://example.com/'),
        throwsFormatException,
      );
      expect(() => validateRoomCode('abc'), throwsFormatException);
      expect(() => validateRoomCode('a' * 65), throwsFormatException);
    },
  );
  test(
    'native capture requests double FPS and exact selected source, not ideal web constraints',
    () {
      const profile = CaptureProfile(height: 1440, fps: 144, mbps: 50);
      final constraints = profile.constraints('window:123');
      final video = constraints['video'] as Map;
      expect((video['deviceId'] as Map)['exact'], 'window:123');
      expect((video['mandatory'] as Map)['frameRate'], isA<double>());
      expect((video['mandatory'] as Map)['frameRate'], 144.0);
      expect((video['mandatory'] as Map)['maxHeight'], 1440);
      expect((constraints['audio'] as Map)['deviceId'], {'exact': '0'});
      expect(
        (profile.constraints('screen', audioSourceId: '123')['audio']
            as Map)['deviceId'],
        {'exact': '123'},
      );
      expect(
        profile.constraints('screen', audioSourceId: null)['audio'],
        false,
      );
    },
  );
  test('does not accept private keys or invalid PEM as a root CA', () {
    for (final value in [
      'not a certificate',
      '-----BEGIN PRIVATE KEY-----',
      'x' * 65537,
    ]) {
      expect(
        () => certificateFingerprint(Uint8List.fromList(utf8.encode(value))),
        throwsFormatException,
      );
    }
  });
  test(
    'native WebSocket sends exact Origin, authenticates and serializes signaling',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      final received = <Map<String, dynamic>>[];
      final serverTask = () async {
        final request = await server.first;
        expect(request.uri.path, '/ws');
        expect(request.headers.value('Origin'), origin.origin);
        final ws = await WebSocketTransformer.upgrade(request);
        final receivedFirst = Completer<Map<String, dynamic>>();
        ws.listen((raw) {
          if (!receivedFirst.isCompleted) {
            receivedFirst.complete(
              jsonDecode(raw as String) as Map<String, dynamic>,
            );
          }
        });
        final first = await receivedFirst.future;
        expect(first['type'], 'join');
        expect(first['roomCode'], 'GOIDA');
        ws.add(jsonEncode({'type': 'joined'}));
        ws.add(jsonEncode({'type': 'signal'}));
      }();
      final client = Signaling();
      try {
        await client.connect(
          origin: origin,
          firstMessage: {'type': 'join', 'roomCode': 'GOIDA'},
          onMessage: (msg) async {
            if (msg['type'] == 'joined') {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            received.add(msg);
          },
          onFailure: (message) => fail(message),
        );
        await serverTask;
        for (var i = 0; i < 50 && received.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(received.map((m) => m['type']), ['joined', 'signal']);
      } finally {
        await client.close();
        await server.close(force: true);
      }
    },
  );
}
