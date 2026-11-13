import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/abordage/wire.dart';
import 'package:pirate_tavern/abordage/transport.dart';
import 'package:pirate_tavern/abordage/mpegts.dart';
import 'package:pirate_tavern/abordage/encoder.dart';
import 'package:pirate_tavern/protocol.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i)),
      prefix = Uint8List.fromList(List.generate(20, (i) => i + 40));
  final id = Uint8List.fromList(List.generate(8, (i) => i + 7));
  final plain = Uint8List.fromList(
    List.generate(maxPlaintext, (i) => (i * 37) % 256),
  );
  test('worker startup errors reach the caller and can be closed', () async {
    final transport = AbordageTransport();
    try {
      await expectLater(
        transport.start(
          {'id': '00', 'key': '00', 'cipherKey': '00', 'noncePrefix': '00'},
          host: '127.0.0.1',
          publish: true,
          onStats: (_) {},
          onFailure: (_) {},
        ),
        throwsA(isA<AbordageException>()),
      );
    } finally {
      await transport.close();
    }
  });
  test('closing during startup cancels without leaving a worker', () async {
    final transport = AbordageTransport();
    final started = transport.start(
      {'id': '00', 'key': '00', 'cipherKey': '00', 'noncePrefix': '00'},
      host: '127.0.0.1',
      publish: true,
      onStats: (_) {},
      onFailure: (_) {},
    );
    final assertion = expectLater(started, throwsA(anything));
    await transport.close();
    await assertion;
  });
  test(
    'late join waits for random access and retains bounded PAT/PMT preroll',
    () {
      final gate = TsJoinGate();
      final plain = Uint8List(188)..[0] = 0x47;
      expect(gate.push(plain), isEmpty);
      expect(gate.push(plain), isEmpty);
      expect(gate.push(plain), isEmpty);
      final key = Uint8List(188)..setAll(0, [0x47, 0x41, 0, 0x30, 1, 0x40]);
      expect(startsKeyframe(key), true);
      expect(gate.push(key).length, 3);
      expect(gate.push(plain), [plain]);
    },
  );
  test('AEAD authenticates ciphertext, timestamp and block number', () async {
    final cipher = BlockCipher(key, prefix, useNative: false);
    final encrypted = await cipher.seal(plain, 7, 120);
    expect(await cipher.open(encrypted, 7, 120), plain);
    await expectLater(cipher.open(encrypted, 8, 120), throwsA(anything));
    await expectLater(cipher.open(encrypted, 7, 121), throwsA(anything));
    final corrupt = Uint8List.fromList(encrypted)..[100] ^= 1;
    await expectLater(cipher.open(corrupt, 7, 120), throwsA(anything));
  });
  test(
    'native AEAD matches independent Dart implementation byte for byte',
    () async {
      final reference = BlockCipher(key, prefix, useNative: false),
          native = BlockCipher(key, prefix);
      final a = await reference.seal(plain, 9, 500),
          b = await native.seal(plain, 9, 500);
      expect(b, a);
      expect(await native.open(a, 9, 500), plain);
      final corrupt = Uint8List.fromList(a)..[9] ^= 1;
      await expectLater(native.open(corrupt, 9, 500), throwsFormatException);
    },
    skip: Platform.environment['ABORDAGE_CRYPTO_LIBRARY'] == null
        ? 'Native library built by CI crypto step'
        : false,
  );
  test(
    'each single lost shard, including parity, recovers in reverse order',
    () async {
      final cipher = BlockCipher(key, prefix, useNative: false);
      final encrypted = await cipher.seal(plain, 1, 100),
          shards = fragment(encrypted);
      for (var missing = 0; missing < shards.length; missing++) {
        final assembler = BlockAssembler();
        for (var i = shards.length - 1; i >= 0; i--) {
          if (i == missing) continue;
          final bytes = makePacket(
            id: id,
            key: key,
            kind: 3,
            sequence: i + 1,
            block: 1,
            timestamp: 100,
            index: i,
            count: shards.length - 1,
            length: encrypted.length,
            payload: shards[i],
          );
          expect(bytes.length, lessThanOrEqualTo(1184));
          assembler.add(WirePacket.parse(bytes, id, key)!, 0);
        }
        final blocks = assembler.drain(1);
        expect(blocks.length, 1);
        expect(await cipher.open(blocks.single.encrypted, 1, 100), plain);
        expect(assembler.recovered, missing < shards.length - 1 ? 1 : 0);
      }
    },
  );
  test(
    'unrecoverable block expires instead of blocking later live data',
    () async {
      final cipher = BlockCipher(key, prefix, useNative: false),
          assembler = BlockAssembler();
      final encrypted = await cipher.seal(plain, 1, 100),
          shards = fragment(encrypted);
      for (var block = 1; block <= 2; block++) {
        for (var i = 0; i < shards.length; i++) {
          if (block == 1 && (i == 0 || i == 1)) continue;
          final packet = makePacket(
            id: id,
            key: key,
            kind: 3,
            sequence: block * 20 + i,
            block: block,
            timestamp: 100,
            index: i,
            count: shards.length - 1,
            length: encrypted.length,
            payload: shards[i],
          );
          assembler.add(WirePacket.parse(packet, id, key)!, 0);
        }
      }
      expect(assembler.drain(10), isEmpty);
      expect(assembler.missing(10), [1]);
      expect(assembler.drain(121).map((b) => b.id), [2]);
      expect(assembler.lost, 1);
    },
  );
  test('wire rejects tampering and replay without allocating an assembly', () {
    final replay = ReplayWindow();
    expect(replay.accept(1000), true);
    expect(replay.accept(999), true);
    expect(replay.accept(999), false);
    expect(replay.accept(1), false);
    final bytes = makePacket(id: id, key: key, kind: 1, sequence: 1);
    expect(WirePacket.parse(bytes, id, key), isNotNull);
    bytes[16] ^= 1;
    expect(WirePacket.parse(bytes, id, key), isNull);
    expect(WirePacket.parse(Uint8List(2000), id, key), isNull);
  });
  test('high FPS uses GPU encoding, bounded GOP and no output FPS filter', () {
    const profile = CaptureProfile(
      height: 1080,
      fps: 120,
      mbps: 50,
      codec: 'h264_nvenc',
    );
    final args = encoderArguments(
      profile,
      'dxgi:1:0',
      'h264_nvenc',
      44000,
      processing: CaptureProcessing.directGpu,
    );
    expect(args, contains('d3d11va=desktop:1'));
    expect(args.join(' '), contains('framerate=120:dup_frames=1'));
    expect(args.join(' '), isNot(contains('scale_d3d11')));
    expect(args, containsAllInOrder(['-g', '30', '-bf', '0']));
    expect(args, contains('ull'));
    expect(args, containsAllInOrder(['-fps_mode', 'passthrough']));
    expect(args, isNot(contains('-r')));
    expect(args.join(' '), isNot(contains('hwdownload')));
    final cpu = encoderArguments(profile, 'dxgi:0:0', 'libx264', 44000);
    expect(cpu.join(' '), contains('hwdownload'));
    expect(cpu, contains('zerolatency'));
  });
}
