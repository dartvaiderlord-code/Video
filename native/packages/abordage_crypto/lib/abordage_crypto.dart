import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

typedef _LockC =
    Void Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
    );
typedef _Lock =
    void Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
    );
typedef _UnlockC =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
    );
typedef _Unlock =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
    );

/// Monocypher 4.0.2, XChaCha20-Poly1305. No custom cryptographic primitives.
class NativeAead {
  NativeAead() {
    final library = DynamicLibrary.open(
      Platform.environment['ABORDAGE_CRYPTO_LIBRARY'] ??
          (Platform.isWindows
              ? 'abordage_crypto.dll'
              : 'libabordage_crypto.so'),
    );
    _lock = library.lookupFunction<_LockC, _Lock>('abr_lock');
    _unlock = library.lookupFunction<_UnlockC, _Unlock>('abr_unlock');
  }
  late final _Lock _lock;
  late final _Unlock _unlock;
  Uint8List transform(
    Uint8List bytes,
    Uint8List key,
    Uint8List nonce,
    Uint8List aad, {
    bool decrypt = false,
  }) {
    if (key.length != 32 ||
        nonce.length != 24 ||
        (decrypt && bytes.length < 16)) {
      throw const FormatException('Invalid AEAD input');
    }
    final size = bytes.length - (decrypt ? 16 : 0);
    final arena = Arena();
    try {
      final input = arena<Uint8>(bytes.length),
          output = arena<Uint8>(size + (decrypt ? 0 : 16));
      final k = arena<Uint8>(32),
          n = arena<Uint8>(24),
          a = arena<Uint8>(aad.length);
      input.asTypedList(bytes.length).setAll(0, bytes);
      k.asTypedList(32).setAll(0, key);
      n.asTypedList(24).setAll(0, nonce);
      a.asTypedList(aad.length).setAll(0, aad);
      if (decrypt) {
        if (_unlock(output, input + size, k, n, a, aad.length, input, size) !=
            0) {
          throw const FormatException('AEAD authentication failed');
        }
      } else {
        _lock(output, output + size, k, n, a, aad.length, input, size);
      }
      return Uint8List.fromList(output.asTypedList(size + (decrypt ? 0 : 16)));
    } finally {
      arena.releaseAll();
    }
  }
}
