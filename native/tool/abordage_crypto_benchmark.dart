import 'dart:typed_data';
import 'package:pirate_tavern/abordage/wire.dart';
import 'dart:io';

Future<void> main() async {
  final c = BlockCipher(Uint8List(32), Uint8List(20));
  final plain = Uint8List(maxPlaintext), id = Uint8List(8), key = Uint8List(32);
  for (var i = 0; i < 20; i++) {
    await c.seal(plain, i + 1, 1);
  }
  final clock = Stopwatch()..start();
  var seq = 0;
  for (var i = 0; i < 1000; i++) {
    final enc = await c.seal(plain, i + 100, 1), shards = fragment(enc);
    for (var j = 0; j < shards.length; j++) {
      final p = makePacket(
        id: id,
        key: key,
        kind: 3,
        sequence: ++seq,
        block: i + 100,
        timestamp: 1,
        index: j,
        count: shards.length - 1,
        length: enc.length,
        payload: shards[j],
      );
      if (WirePacket.parse(p, id, key) == null) throw StateError('MAC');
    }
    await c.open(enc, i + 100, 1);
  }
  stdout.writeln(
    'XChaCha20-Poly1305 + FEC + two MACs roundtrip: ${(1000 * maxPlaintext * 8 / clock.elapsedMicroseconds).toStringAsFixed(1)} Mbit/s',
  );
}
