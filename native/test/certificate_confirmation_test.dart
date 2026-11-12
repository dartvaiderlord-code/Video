import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/certificate_trust.dart';
import 'package:pirate_tavern/protocol.dart';
import 'package:pirate_tavern/signaling.dart';

class _TlsSite {
  _TlsSite(this.directory);
  final Directory directory;
  HttpServer? server;
  final sockets = <WebSocket>[];
  int messages = 0;
  Uri get origin => Uri.parse('https://127.0.0.1:${server!.port}');
  Future<void> start(String identity, {int port = 0}) async {
    final cert = '${directory.path}/$identity.crt',
        key = '${directory.path}/$identity.key';
    final generation = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '1',
      '-subj',
      '/CN=$identity',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
    ]);
    expect(generation.exitCode, 0);
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      port,
      context,
    );
    server!.listen(
      (request) async {
        final ws = await WebSocketTransformer.upgrade(request);
        sockets.add(ws);
        ws.listen((raw) {
          expect((jsonDecode(raw as String) as Map)['type'], 'create');
          messages++;
          ws.add(jsonEncode({'type': 'created'}));
        });
      },
      onError: (Object _) {
        /* Rejected TLS handshakes are expected. */
      },
    );
  }

  Future<void> rotate() async {
    final port = server!.port;
    await server!.close(force: true);
    await start('changed', port: port);
  }

  Future<void> dispose() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await server?.close(force: true);
    await directory.delete(recursive: true);
  }
}

Future<_TlsSite> _site() async {
  final site = _TlsSite(
    await Directory.systemTemp.createTemp('pirate-confirm-'),
  );
  await site.start('original');
  return site;
}

Future<void> _connect(
  Signaling client,
  _TlsSite site, {
  String? pin,
  CertificateApprover? confirm,
  CertificateRememberer? remember,
}) async {
  final ready = Completer<void>();
  await client.connect(
    origin: site.origin,
    certificatePin: pin,
    confirmCertificate: confirm,
    onCertificateRemembered: remember,
    firstMessage: {'type': 'create', 'roomCode': 'private-room-code'},
    onMessage: (msg) async {
      if (msg['type'] == 'created') ready.complete();
    },
    onFailure: (message) => fail(message),
  );
  await ready.future.timeout(const Duration(seconds: 5));
}

void main() {
  test(
    'confirmation precedes credentials; a remembered exact certificate reconnects without prompting',
    () async {
      final site = await _site();
      final first = Signaling(), second = Signaling();
      String? pin;
      try {
        await _connect(
          first,
          site,
          confirm: (cert) async {
            expect(site.messages, 0);
            expect(cert.origin, site.origin);
            expect(cert.changed, false);
            final pem = await File(
              '${site.directory.path}/original.crt',
            ).readAsBytes();
            expect(cert.fingerprint, certificateFingerprint(pem));
            return CertificateAcceptance.remember;
          },
          remember: (cert) async {
            pin = cert.fingerprint;
          },
        );
        expect(site.messages, 1);
        expect(pin, isNotNull);
        await first.close();
        await _connect(
          second,
          site,
          pin: pin,
          confirm: (_) async {
            fail('An unchanged remembered certificate must not prompt again.');
          },
        );
        expect(site.messages, 2);
      } finally {
        await first.close();
        await second.close();
        await site.dispose();
      }
    },
  );

  test(
    'reject sends no credentials; allow-once never persists trust',
    () async {
      final site = await _site();
      final rejected = Signaling(), once = Signaling();
      try {
        await expectLater(
          _connect(
            rejected,
            site,
            confirm: (_) async => CertificateAcceptance.reject,
          ),
          throwsA(isA<CertificateDeclinedException>()),
        );
        expect(site.messages, 0);
        await _connect(
          once,
          site,
          confirm: (_) async => CertificateAcceptance.once,
          remember: (_) async {
            fail('Allow-once must not save a pin.');
          },
        );
        expect(site.messages, 1);
      } finally {
        await rejected.close();
        await once.close();
        await site.dispose();
      }
    },
  );

  test(
    'a changed certificate prompts again; a second change during confirmation is rejected',
    () async {
      final site = await _site();
      final initial = Signaling(), changed = Signaling();
      String? pin;
      try {
        await _connect(
          initial,
          site,
          confirm: (_) async => CertificateAcceptance.remember,
          remember: (cert) async {
            pin = cert.fingerprint;
          },
        );
        await initial.close();
        await site.rotate();
        await _connect(
          changed,
          site,
          pin: pin,
          confirm: (cert) async {
            expect(cert.changed, true);
            expect(cert.previousFingerprint, pin);
            expect(cert.fingerprint, isNot(pin));
            return CertificateAcceptance.once;
          },
        );
        await changed.close();
      } finally {
        await initial.close();
        await changed.close();
        await site.dispose();
      }

      final race = await _site();
      final client = Signaling();
      var stored = false;
      try {
        await expectLater(
          _connect(
            client,
            race,
            confirm: (_) async {
              await race.rotate();
              return CertificateAcceptance.remember;
            },
            remember: (_) async {
              stored = true;
            },
          ),
          throwsA(isA<HandshakeException>()),
        );
        expect(race.messages, 0);
        expect(stored, false);
      } finally {
        await client.close();
        await race.dispose();
      }
    },
  );

  test(
    'closing while approval is pending cancels without remembering or sending a room code',
    () async {
      final site = await _site();
      final client = Signaling();
      final prompted = Completer<void>(),
          answer = Completer<CertificateAcceptance>();
      try {
        final connecting = client.connect(
          origin: site.origin,
          firstMessage: {'type': 'create', 'roomCode': 'private'},
          confirmCertificate: (_) async {
            prompted.complete();
            return answer.future;
          },
          onCertificateRemembered: (_) async {
            fail('Cancelled approval must not persist.');
          },
          onMessage: (_) async {
            fail('Cancelled connection must not authenticate.');
          },
          onFailure: (_) {},
        );
        await prompted.future.timeout(const Duration(seconds: 5));
        await client.close();
        answer.complete(CertificateAcceptance.remember);
        await connecting;
        expect(site.messages, 0);
      } finally {
        await client.close();
        await site.dispose();
      }
    },
  );
}
