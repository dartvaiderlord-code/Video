import 'dart:typed_data';
import 'package:abordage_crypto/abordage_crypto.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

const shardSize = 1136, headerSize = 32, macSize = 16;
const maxPlaintext = 9024; // 48 MPEG-TS packets. Datagram incl. MAC <= 1184 B.
Uint8List unhex(String text) {
  if (text.length.isOdd || !RegExp(r'^[0-9a-f]+$').hasMatch(text)) {
    throw const FormatException('Invalid Abordage key');
  }
  return Uint8List.fromList([
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ]);
}

class ReplayWindow {
  int high = -1;
  BigInt bits = BigInt.zero;
  bool accept(int seq) {
    if (seq > high) {
      final jump = seq - high;
      bits = jump >= 256
          ? BigInt.one
          : ((bits << jump) | BigInt.one) & ((BigInt.one << 256) - BigInt.one);
      high = seq;
      return true;
    }
    final delta = high - seq;
    if (delta >= 256 || (bits & (BigInt.one << delta)) != BigInt.zero) {
      return false;
    }
    bits |= BigInt.one << delta;
    return true;
  }
}

class WirePacket {
  WirePacket(this.bytes);
  final Uint8List bytes;
  late final ByteData data = ByteData.sublistView(bytes);
  int get kind => bytes[4];
  int get index => bytes[6];
  int get count => bytes[7];
  int get sequence => data.getUint32(16);
  int get block => data.getUint32(20);
  int get length => data.getUint32(24);
  int get timestamp => data.getUint32(28);
  Uint8List get payload => Uint8List.sublistView(bytes, 32, bytes.length - 16);
  static WirePacket? parse(Uint8List bytes, Uint8List id, List<int> key) {
    if (bytes.length < 48 ||
        bytes.length > 1184 ||
        bytes[0] != 65 ||
        bytes[1] != 66 ||
        bytes[2] != 82 ||
        bytes[3] != 49 ||
        bytes[5] != 0) {
      return null;
    }
    var mismatch = 0;
    for (var i = 0; i < 8; i++) {
      mismatch |= bytes[8 + i] ^ id[i];
    }
    final mac = hash.Hmac(
      hash.sha256,
      key,
    ).convert(Uint8List.sublistView(bytes, 0, bytes.length - 16)).bytes;
    for (var i = 0; i < 16; i++) {
      mismatch |= mac[i] ^ bytes[bytes.length - 16 + i];
    }
    if (mismatch != 0) return null;
    final p = WirePacket(bytes);
    if (![1, 2, 3, 4, 5].contains(p.kind)) return null;
    if (p.kind == 3) {
      if (p.count < 1 ||
          p.count > 8 ||
          p.index > p.count ||
          p.length < 17 ||
          p.length > p.count * shardSize ||
          (p.length + shardSize - 1) ~/ shardSize != p.count) {
        return null;
      }
      final expected = p.index == p.count
          ? shardSize
          : (p.index == p.count - 1
                ? p.length - p.index * shardSize
                : shardSize);
      if (p.payload.length != expected) return null;
    } else if (bytes.length != 48 ||
        p.index != 0 ||
        p.count != 0 ||
        p.length != 0) {
      return null;
    }
    return p;
  }
}

Uint8List makePacket({
  required Uint8List id,
  required List<int> key,
  required int kind,
  required int sequence,
  int block = 0,
  int timestamp = 0,
  int index = 0,
  int count = 0,
  int length = 0,
  List<int> payload = const [],
}) {
  if (sequence < 0 || sequence > 0xffffffff) {
    throw StateError('Reconnect before nonce/sequence rollover');
  }
  final bytes = Uint8List(48 + payload.length),
      data = ByteData.sublistView(bytes);
  bytes.setAll(0, [65, 66, 82, 49, kind, 0, index, count]);
  bytes.setAll(8, id);
  data.setUint32(16, sequence);
  data.setUint32(20, block);
  data.setUint32(24, length);
  data.setUint32(28, timestamp);
  bytes.setAll(32, payload);
  bytes.setAll(
    bytes.length - 16,
    hash.Hmac(hash.sha256, key)
        .convert(Uint8List.sublistView(bytes, 0, bytes.length - 16))
        .bytes
        .take(16),
  );
  return bytes;
}

Uint8List blockNonce(Uint8List prefix, int block) =>
    (Uint8List(24)..setAll(0, prefix)).tapBlock(block);

extension on Uint8List {
  Uint8List tapBlock(int block) {
    ByteData.sublistView(this).setUint32(20, block);
    return this;
  }
}

Uint8List blockAad(Uint8List prefix, int block, int timestamp, int length) {
  final bytes = Uint8List(36)
    ..setAll(0, [65, 66, 82, 49])
    ..setAll(4, prefix);
  final data = ByteData.sublistView(bytes);
  data.setUint32(24, block);
  data.setUint32(28, timestamp);
  data.setUint32(32, length);
  return bytes;
}

class BlockCipher {
  BlockCipher(this.rawKey, this.prefix, {bool useNative = true})
    : key = SecretKey(rawKey),
      native = useNative ? NativeAead() : null;
  final Uint8List rawKey;
  final NativeAead? native;
  final SecretKey key;
  final Uint8List prefix;
  final algorithm = Xchacha20.poly1305Aead();
  Future<Uint8List> seal(List<int> plain, int block, int timestamp) async {
    if (block <= 0 ||
        block > 0xffffffff ||
        plain.isEmpty ||
        plain.length > maxPlaintext ||
        plain.length % 188 != 0) {
      throw const FormatException('Invalid TS block');
    }
    if (native != null) {
      return native!.transform(
        Uint8List.fromList(plain),
        rawKey,
        blockNonce(prefix, block),
        blockAad(prefix, block, timestamp, plain.length + 16),
      );
    }
    final box = await algorithm.encrypt(
      plain,
      secretKey: key,
      nonce: blockNonce(prefix, block),
      aad: blockAad(prefix, block, timestamp, plain.length + 16),
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> open(List<int> encrypted, int block, int timestamp) async {
    if (encrypted.length < 17 ||
        encrypted.length > maxPlaintext + 16 ||
        (encrypted.length - 16) % 188 != 0 ||
        block <= 0 ||
        block > 0xffffffff) {
      throw const FormatException('Invalid block length');
    }
    if (native != null) {
      return native!.transform(
        Uint8List.fromList(encrypted),
        rawKey,
        blockNonce(prefix, block),
        blockAad(prefix, block, timestamp, encrypted.length),
        decrypt: true,
      );
    }
    final plain = await algorithm.decrypt(
      SecretBox(
        encrypted.sublist(0, encrypted.length - 16),
        nonce: blockNonce(prefix, block),
        mac: Mac(encrypted.sublist(encrypted.length - 16)),
      ),
      secretKey: key,
      aad: blockAad(prefix, block, timestamp, encrypted.length),
    );
    if (plain.length % 188 != 0) {
      throw const FormatException('Unaligned TS block');
    }
    return Uint8List.fromList(plain);
  }
}

List<Uint8List> fragment(Uint8List encrypted) {
  final count = (encrypted.length + shardSize - 1) ~/ shardSize;
  final result = <Uint8List>[], parity = Uint8List(shardSize);
  for (var i = 0; i < count; i++) {
    final end = (i + 1) * shardSize < encrypted.length
        ? (i + 1) * shardSize
        : encrypted.length;
    final shard = Uint8List.sublistView(encrypted, i * shardSize, end);
    result.add(shard);
    for (var j = 0; j < shard.length; j++) {
      parity[j] ^= shard[j];
    }
  }
  return [...result, parity];
}

class _Group {
  _Group(WirePacket p, this.created)
    : length = p.length,
      count = p.count,
      timestamp = p.timestamp;
  final int length, count, timestamp, created;
  final shards = <int, Uint8List>{};
  Uint8List? finish() {
    if (shards.length < count) return null;
    final missing = [
      for (var i = 0; i < count; i++)
        if (!shards.containsKey(i)) i,
    ];
    if (missing.length > 1 ||
        (missing.isNotEmpty && !shards.containsKey(count))) {
      return null;
    }
    if (missing.isNotEmpty) {
      final recovered = Uint8List.fromList(shards[count]!);
      for (var i = 0; i < count; i++) {
        final shard = shards[i];
        if (shard == null) continue;
        for (var j = 0; j < shard.length; j++) {
          recovered[j] ^= shard[j];
        }
      }
      shards[missing.single] = recovered;
    }
    final out = Uint8List(length);
    for (var i = 0; i < count; i++) {
      final end = (i + 1) * shardSize < length ? (i + 1) * shardSize : length;
      out.setRange(i * shardSize, end, shards[i]!);
    }
    return out;
  }
}

class ReadyBlock {
  ReadyBlock(this.id, this.timestamp, this.encrypted);
  final int id, timestamp;
  final Uint8List encrypted;
}

/// A bounded reorder window. Never wait indefinitely for an old screen frame.
class BlockAssembler {
  final _groups = <int, _Group>{};
  int _last = 0;
  int recovered = 0, lost = 0;
  final _requested = <int, int>{};
  List<int> missing(int now) {
    if (_groups.isEmpty) return [];
    final highest = _groups.keys.reduce((a, b) => a > b ? a : b);
    final firstCreated = _groups.values
        .map((g) => g.created)
        .reduce((a, b) => a < b ? a : b);
    final out = <int>[];
    for (var id = _last + 1; id <= highest && out.length < 4; id++) {
      final g = _groups[id];
      if (g != null && g.shards.length >= g.count) continue;
      final age = now - (g?.created ?? firstCreated);
      if (age < 8 || age >= 120 || now - (_requested[id] ?? -100) < 35) {
        continue;
      }
      _requested[id] = now;
      out.add(id);
    }
    return out;
  }

  void add(WirePacket p, int now) {
    if (p.block <= _last || p.block == 0) return;
    if (_last == 0 && _groups.isEmpty) _last = p.block - 1;
    if (_groups.length >= 128 && !_groups.containsKey(p.block)) {
      final oldest = _groups.keys.reduce((a, b) => a < b ? a : b);
      _groups.remove(oldest);
      lost++;
    }
    final g = _groups.putIfAbsent(p.block, () => _Group(p, now));
    if (g.count != p.count ||
        g.length != p.length ||
        g.timestamp != p.timestamp) {
      return;
    }
    g.shards.putIfAbsent(p.index, () => Uint8List.fromList(p.payload));
  }

  List<ReadyBlock> drain(int now) {
    final out = <ReadyBlock>[];
    for (final id in (_groups.keys.toList()..sort())) {
      if (id <= _last) {
        _groups.remove(id);
        continue;
      }
      final g = _groups[id]!;
      if (id > _last + 1 && now - g.created < 120 && _groups.length < 120) {
        break;
      }
      final lackedData =
          g.shards.keys.where((i) => i < g.count).length < g.count;
      final bytes = g.finish();
      if (bytes == null && now - g.created < 120 && _groups.length < 120) break;
      if (id > _last + 1) lost += id - _last - 1;
      _last = id;
      _requested.removeWhere((number, _) => number <= id);
      _groups.remove(id);
      if (bytes == null) {
        lost++;
        continue;
      }
      if (lackedData) recovered++;
      out.add(ReadyBlock(id, g.timestamp, bytes));
    }
    return out;
  }
}
