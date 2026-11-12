import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/protocol.dart';
import 'package:pirate_tavern/signaling.dart';

void main() {
  test(
    'self-hosted CA requires explicit trust and has the expected SHA-256 fingerprint',
    () async {
      final dir = await Directory.systemTemp.createTemp('pirate-tls-');
      final ca = File('${dir.path}/root.crt'),
          key = File('${dir.path}/key.pem');
      HttpServer? server;
      final accepted = Signaling(), rejected = Signaling();
      try {
        final generation = await Process.run('openssl', [
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-keyout',
          key.path,
          '-out',
          ca.path,
          '-days',
          '1',
          '-subj',
          '/CN=Pirate TLS test',
          '-addext',
          'subjectAltName=IP:127.0.0.1',
        ]);
        expect(
          generation.exitCode,
          0,
          reason: 'OpenSSL is required for the TLS integration test.',
        );
        final bytes = await ca.readAsBytes();
        final fingerprint = certificateFingerprint(bytes);
        final official = await Process.run('openssl', [
          'x509',
          '-in',
          ca.path,
          '-noout',
          '-sha256',
          '-fingerprint',
        ]);
        expect((official.stdout as String).trim().split('=').last, fingerprint);
        final context = SecurityContext()
          ..useCertificateChain(ca.path)
          ..usePrivateKey(key.path);
        server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        final origin = Uri.parse('https://127.0.0.1:${server.port}');
        server.listen(
          (request) async {
            expect(request.headers.value('Origin'), origin.origin);
            final ws = await WebSocketTransformer.upgrade(request);
            ws.listen((raw) {
              expect((jsonDecode(raw as String) as Map)['type'], 'create');
              ws.add(jsonEncode({'type': 'created'}));
            });
          },
          onError: (Object _) {
            /* The first test connection intentionally rejects the CA. */
          },
        );
        await expectLater(
          rejected.connect(
            origin: origin,
            firstMessage: {'type': 'create'},
            onMessage: (_) async {},
            onFailure: (_) {},
          ),
          throwsA(isA<HandshakeException>()),
        );
        final ready = Completer<void>();
        await accepted.connect(
          origin: origin,
          trustedCa: bytes,
          firstMessage: {'type': 'create'},
          onMessage: (msg) async {
            if (msg['type'] == 'created') ready.complete();
          },
          onFailure: (message) => fail(message),
        );
        await ready.future.timeout(const Duration(seconds: 5));
      } finally {
        await accepted.close();
        await rejected.close();
        await server?.close(force: true);
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
