import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Uses the same /ws protocol as the web client, including its exact Origin.
/// A selected CA extends trust only for this connection; no badCertificateCallback.
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
    required Map<String, dynamic> firstMessage,
    required Future<void> Function(Map<String, dynamic>) onMessage,
    required void Function(String) onFailure,
  }) async {
    final context = SecurityContext(withTrustedRoots: true);
    if (trustedCa != null) context.setTrustedCertificatesBytes(trustedCa);
    _http = HttpClient(context: context)
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final ws = await WebSocket.connect(
        origin
            .replace(
              scheme: origin.scheme == 'https' ? 'wss' : 'ws',
              path: '/ws',
            )
            .toString(),
        headers: {'Origin': origin.origin},
        customClient: _http,
      ).timeout(const Duration(seconds: 15));
      if (_closed) {
        await ws.close();
        return;
      }
      _socket = ws;
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
