import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Uri serverOrigin(String text, {bool allowHttpForTests = false}) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.scheme != 'https' && !(allowHttpForTests && uri.scheme == 'http')) ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery) {
    throw const FormatException(
      'Укажите https://адрес:порт без пути и логина.',
    );
  }
  return Uri.parse(uri.origin);
}

class RoomInvite {
  RoomInvite(this.server, this.room, this.token);
  factory RoomInvite.parse(String text, {bool allowHttpForTests = false}) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null) throw const FormatException('Неверная ссылка комнаты.');
    final origin = serverOrigin(text, allowHttpForTests: allowHttpForTests);
    final fields = Uri.splitQueryString(uri.fragment);
    final room = fields['room'] ?? '', token = fields['token'] ?? '';
    if (!RegExp(r'^[a-f0-9]{24}$').hasMatch(room) ||
        !RegExp(r'^[a-f0-9]{48}$').hasMatch(token)) {
      throw const FormatException(
        'Вставьте полную ссылку с room и token после #.',
      );
    }
    return RoomInvite(origin, room, token);
  }
  final Uri server;
  final String room;
  final String token;
  String get link => '${server.origin}/#room=$room&token=$token';
  Map<String, dynamic> join(String code) => {
    'type': 'join',
    'room': room,
    'token': token,
    'roomCode': validateRoomCode(code),
  };
}

String validateRoomCode(String text) {
  final code = text.trim();
  if (code.length < 4 || code.length > 64) {
    throw const FormatException('Код комнаты: от 4 до 64 символов.');
  }
  return code;
}

class CaptureProfile {
  const CaptureProfile({
    this.height = 1080,
    this.fps = 120,
    this.mbps = 35,
    this.codec = 'H264',
    this.keepResolution = true,
    this.fullQuality = true,
  });
  final int height, fps, mbps;
  final String codec;
  final bool keepResolution;
  final bool fullQuality;
  int get width => (height * 16 / 9).round();
  Map<String, dynamic> constraints(
    String sourceId, {
    String? audioSourceId = '0',
  }) => {
    'audio': audioSourceId == null
        ? false
        : {
            'deviceId': {'exact': audioSourceId},
          },
    'video': {
      'deviceId': {'exact': sourceId},
      'cursor': 'always',
      // The native desktop plugin reads this field as a double, not the web API's ideal.
      'mandatory': {
        'frameRate': fps.toDouble(),
        'maxWidth': width,
        'maxHeight': height,
      },
    },
  };
}

/// Validate a PEM CA, retain normal TLS verification, and show an OpenSSL-compatible
/// fingerprint of the DER certificate, not a hash of the PEM text.
String certificateFingerprint(Uint8List bytes) {
  if (bytes.length > 65536) {
    throw const FormatException('Сертификат больше 64 КиБ.');
  }
  final pem = utf8.decode(bytes);
  if (pem.contains('PRIVATE KEY')) {
    throw const FormatException('Нужен публичный root.crt, не приватный ключ.');
  }
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (match == null) {
    throw const FormatException(
      'Выберите корневой сертификат PEM (.crt/.pem).',
    );
  }
  SecurityContext(withTrustedRoots: true).setTrustedCertificatesBytes(bytes);
  return derFingerprint(base64.decode(match[1]!.replaceAll(RegExp(r'\s'), '')));
}

String derFingerprint(List<int> bytes) => sha256
    .convert(bytes)
    .toString()
    .toUpperCase()
    .replaceAllMapped(RegExp(r'.{2}(?!$)'), (m) => '${m[0]}:');
