import 'dart:collection';
import 'dart:typed_data';

/// RawDatagramSocket.send may return zero while Windows finishes a prior send.
/// Keep that datagram until the socket reports writable; never build latency
/// without a bound when the actual connection cannot carry the selected rate.
class DatagramSendQueue {
  DatagramSendQueue({
    required this.send,
    required this.writeInterest,
    required this.nowMilliseconds,
    this.maxBytes = 2 * 1024 * 1024,
    this.maxAgeMilliseconds = 120,
  });

  final int Function(Uint8List) send;
  final void Function(bool) writeInterest;
  final int Function() nowMilliseconds;
  final int maxBytes, maxAgeMilliseconds;
  final _queue = Queue<(Uint8List, int)>();
  bool _waiting = false;
  int queuedBytes = 0, blocked = 0, dropped = 0, sent = 0;

  void add(Uint8List packet) {
    if (packet.length > maxBytes) {
      dropped++;
      return;
    }
    // The normal path needs neither allocation nor an OS write-interest change.
    if (_queue.isEmpty && !_waiting) {
      final count = send(packet);
      if (count == packet.length) {
        sent++;
        return;
      }
      if (count != 0) {
        throw StateError('UDP send returned a partial datagram');
      }
      blocked++;
      _waiting = true;
      writeInterest(true);
    }
    while (queuedBytes + packet.length > maxBytes && _queue.isNotEmpty) {
      queuedBytes -= _queue.removeFirst().$1.length;
      dropped++;
    }
    _queue.add((packet, nowMilliseconds()));
    queuedBytes += packet.length;
    if (!_waiting) flush();
  }

  void flush() {
    if (_waiting) {
      _waiting = false;
      writeInterest(false);
    }
    while (_queue.isNotEmpty) {
      final entry = _queue.first;
      if (nowMilliseconds() - entry.$2 > maxAgeMilliseconds) {
        queuedBytes -= _queue.removeFirst().$1.length;
        dropped++;
        continue;
      }
      final count = send(entry.$1);
      if (count == 0) {
        blocked++;
        _waiting = true;
        writeInterest(true);
        return;
      }
      if (count != entry.$1.length) {
        throw StateError('UDP send returned a partial datagram');
      }
      queuedBytes -= _queue.removeFirst().$1.length;
      sent++;
    }
  }
}
