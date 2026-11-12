import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'certificate_trust.dart';

/// Uses the same /ws protocol as the web client, including its exact Origin.
/// A selected CA or explicitly confirmed leaf is scoped to this connection.
class Signaling {
  WebSocket? _socket;
  HttpClient? _http;
  StreamSubscription<dynamic>? _subscription;
  Timer? _handshakeTimer;
  bool _closed = false;
  Future<void> _messages = Future.value();

  Future<void> connect({
    required Uri origin,
    Uint8List? trustedCa,
    String? certificatePin,
    CertificateApprover? confirmCertificate,
    CertificateRememberer? onCertificateRemembered,
    required Map<String, dynamic> firstMessage,
    required Future<void> Function(Map<String, dynamic>) onMessage,
    required void Function(String) onFailure,
  }) async {
    final context = SecurityContext(withTrustedRoots: true);
    if (trustedCa != null) context.setTrustedCertificatesBytes(trustedCa);
    WebSocket? opened;
    ServerCertificate? remembered;
    String? approvedPin = certificatePin;
    try {
      // The first failed handshake discovers the certificate without sending
      // room credentials. The second connection accepts only that exact DER hash.
      for (var attempt = 0; attempt < 2; attempt++) {
        ServerCertificate? presented;
        _http = HttpClient(context: context)
          ..connectionTimeout = const Duration(seconds: 12)
          ..badCertificateCallback = (certificate, host, port) {
            if (_closed ||
                host.toLowerCase() != origin.host.toLowerCase() ||
                port != origin.port) {
              return false;
            }
            presented = ServerCertificate.fromX509(
              origin,
              certificate,
              previousFingerprint: certificatePin,
            );
            return approvedPin != null && presented!.fingerprint == approvedPin;
          };
        try {
          opened = await WebSocket.connect(
            origin
                .replace(
                  scheme: origin.scheme == 'https' ? 'wss' : 'ws',
                  path: '/ws',
                )
                .toString(),
            headers: {'Origin': origin.origin},
            customClient: _http,
          ).timeout(const Duration(seconds: 15));
          break;
        } on HandshakeException {
          _http?.close(force: true);
          if (_closed) return;
          final candidate = presented;
          if (attempt != 0 || candidate == null || confirmCertificate == null) {
            rethrow;
          }
          final decision = await confirmCertificate(candidate);
          if (_closed) return;
          if (decision == CertificateAcceptance.reject) {
            throw CertificateDeclinedException();
          }
          approvedPin = candidate.fingerprint;
          if (decision == CertificateAcceptance.remember) {
            remembered = candidate;
          }
        }
      }
      final ws = opened;
      if (ws == null) {
        throw StateError('Не удалось подтвердить сертификат сервера.');
      }
      if (_closed) {
        await ws.close();
        return;
      }
      _socket = ws;
      if (remembered != null && onCertificateRemembered != null) {
        await onCertificateRemembered(remembered);
      }
      if (_closed) {
        await ws.close();
        return;
      }
      ws.pingInterval = const Duration(seconds: 15);
      _handshakeTimer = Timer(const Duration(seconds: 15), () {
        if (!_closed) onFailure('Сервер не подтвердил подключение.');
      });
      _subscription = ws.listen(
        (raw) {
          _messages = _messages
              .then((_) async {
                if (_closed) return;
                final decoded = jsonDecode(raw as String);
                if (decoded is! Map<String, dynamic>) {
                  throw const FormatException('Неверный ответ сервера.');
                }
                if (['created', 'joined', 'error'].contains(decoded['type'])) {
                  _handshakeTimer?.cancel();
                }
                await onMessage(decoded);
              })
              .catchError((Object _) {
                if (!_closed) onFailure('Ошибка обработки сообщения сервера.');
              });
        },
        onError: (Object _) {
          if (!_closed) onFailure('Ошибка канала сигнализации.');
        },
        onDone: () {
          if (!_closed) onFailure('Соединение закрыто. Подключитесь заново.');
        },
      );
      send(firstMessage);
    } catch (_) {
      await opened?.close();
      _http?.close(force: true);
      rethrow;
    }
  }

  void send(Map<String, dynamic> message) {
    if (!_closed && _socket?.readyState == WebSocket.open) {
      _socket!.add(jsonEncode(message));
    }
  }

  Future<void> close() async {
    _closed = true;
    _handshakeTimer?.cancel();
    await _subscription?.cancel();
    await _socket?.close();
    _http?.close(force: true);
  }
}
