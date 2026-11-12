import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/protocol.dart';
import 'package:pirate_tavern/signaling.dart';
import 'package:pirate_tavern/room_chat.dart';

void main() {
  test(
    'native clients create, authenticate, signal and end a room on the real Node server',
    () async {
      final server = await Process.start('node', [
        '../scripts/native-test-server.mjs',
      ]);
      final host = Signaling(), bad = Signaling(), viewer = Signaling();
      final hostChat = RoomChat(host.send), viewerChat = RoomChat(viewer.send);
      final hostRoster = Completer<void>(),
          viewerRoster = Completer<void>(),
          chatReceived = Completer<void>();
      try {
        final url = await server.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        final origin = serverOrigin(url, allowHttpForTests: true);
        final created = Completer<Map<String, dynamic>>();
        final arrival = Completer<Map<String, dynamic>>();
        final hostSignal = Completer<Map<String, dynamic>>();
        await host.connect(
          origin: origin,
          firstMessage: {'type': 'create', 'roomCode': 'Код команды'},
          onMessage: (msg) async {
            if (msg['type'] == 'created') {
              hostChat.selfId = msg['id'] as String;
              created.complete(msg);
            }
            if (['members', 'chat'].contains(msg['type'])) {
              await hostChat.handle(msg);
            }
            if (hostChat.members.length == 2 && !hostRoster.isCompleted) {
              hostRoster.complete();
            }
            if (msg['type'] == 'viewer-joined') arrival.complete(msg);
            if (msg['type'] == 'signal') hostSignal.complete(msg);
          },
          onFailure: (message) => fail(message),
        );
        final room = await created.future.timeout(const Duration(seconds: 5));
        final invite = RoomInvite(
          origin,
          room['room'] as String,
          room['token'] as String,
        );
        final denied = Completer<Map<String, dynamic>>();
        await bad.connect(
          origin: origin,
          firstMessage: invite.join('wrong-code'),
          onMessage: (msg) async {
            denied.complete(msg);
          },
          onFailure: (message) => fail(message),
        );
        expect((await denied.future)['type'], 'error');
        await bad.close();
        final joined = Completer<void>(), ended = Completer<void>();
        final offer = Completer<Map<String, dynamic>>();
        await viewer.connect(
          origin: origin,
          firstMessage: invite.join('Код команды'),
          onMessage: (msg) async {
            if (msg['type'] == 'joined') {
              viewerChat.selfId = msg['id'] as String;
              joined.complete();
            }
            if (['members', 'chat'].contains(msg['type'])) {
              await viewerChat.handle(msg);
            }
            if (viewerChat.members.length == 2 && !viewerRoster.isCompleted) {
              viewerRoster.complete();
            }
            if (msg['type'] == 'chat' && !chatReceived.isCompleted) {
              chatReceived.complete();
            }
            if (msg['type'] == 'signal') offer.complete(msg);
            if (msg['type'] == 'ended') ended.complete();
          },
          onFailure: (_) {
            /* Host termination also closes this socket. */
          },
        );
        await joined.future.timeout(const Duration(seconds: 5));
        await Future.wait([
          hostRoster.future,
          viewerRoster.future,
        ]).timeout(const Duration(seconds: 5));
        expect(hostChat.supported, true);
        expect(viewerChat.supported, true);
        expect(hostChat.post('Native room chat works'), true);
        await chatReceived.future.timeout(const Duration(seconds: 5));
        expect(viewerChat.messages.single.text, 'Native room chat works');
        expect(viewerChat.messages.single.name, 'Капитан');
        final id = (await arrival.future)['id'];
        host.send({
          'type': 'signal',
          'to': id,
          'data': {
            'description': {'type': 'offer', 'sdp': 'native-offer'},
          },
        });
        expect(
          ((await offer.future)['data'] as Map)['description']['sdp'],
          'native-offer',
        );
        viewer.send({
          'type': 'signal',
          'data': {
            'candidate': {'candidate': 'native-candidate'},
          },
        });
        expect((await hostSignal.future)['from'], id);
        await host.close();
        await ended.future.timeout(const Duration(seconds: 5));
      } finally {
        await host.close();
        await bad.close();
        await viewer.close();
        server.kill();
        await server.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            server.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
