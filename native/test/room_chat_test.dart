import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/room_chat.dart';

const stream = {
  'streamId': 'voice-stream',
  'audioTracks': [
    {
      'id': 'mic-track',
      'label': 'Microphone',
      'kind': 'audio',
      'enabled': true,
    },
  ],
  'videoTracks': [],
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final calls = <MethodCall>[];
  final sent = <Map<String, dynamic>>[];
  late RoomChat chat;
  Future<Object?> Function(MethodCall)? media;
  setUp(() {
    calls.clear();
    sent.clear();
    media = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getUserMedia') {
            return media == null ? stream : await media!(call);
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          (_) async => null,
        );
    chat = RoomChat(sent.add);
  });
  tearDown(() async {
    await chat.reset();
    chat.dispose();
  });
  test(
    'text/membership never request microphone; voice is explicit, mutable and released',
    () async {
      await chat.handle({
        'type': 'members',
        'members': [
          {'id': 'self', 'name': 'Капитан', 'voice': false},
        ],
      });
      chat.post('hello');
      expect(calls.where((c) => c.method == 'getUserMedia'), isEmpty);
      expect(chat.enabled, false);
      await chat.toggleVoice();
      expect(calls.where((c) => c.method == 'getUserMedia').length, 1);
      expect(chat.enabled, true);
      chat.toggleMute();
      expect(chat.muted, true);
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.any(
          (c) =>
              c.method == 'mediaStreamTrackSetEnable' &&
              (c.arguments as Map)['enabled'] == false,
        ),
        true,
      );
      await chat.leave();
      expect(chat.enabled, false);
      expect(
        calls.any(
          (c) =>
              c.method == 'trackDispose' &&
              (c.arguments as Map)['trackId'] == 'mic-track',
        ),
        true,
      );
      expect(calls.any((c) => c.method == 'streamDispose'), true);
    },
  );
  test(
    'leaving while permission is pending stops the late microphone',
    () async {
      final started = Completer<void>(), pending = Completer<Object?>();
      media = (_) {
        started.complete();
        return pending.future;
      };
      final joining = chat.toggleVoice();
      await started.future;
      await chat.reset();
      pending.complete(stream);
      await joining;
      expect(chat.enabled, false);
      expect(
        sent.any((m) => m['type'] == 'voice-state' && m['enabled'] == true),
        false,
      );
      expect(calls.any((c) => c.method == 'trackDispose'), true);
    },
  );
  test(
    'permission denial keeps voice off without breaking text chat',
    () async {
      media = (_) async =>
          throw PlatformException(code: 'PermissionDenied', message: 'denied');
      await chat.toggleVoice();
      expect(chat.enabled, false);
      expect(chat.error, contains('Микрофон недоступен'));
      chat.post('still here');
      expect(sent.last, {'type': 'chat', 'text': 'still here'});
    },
  );
}
