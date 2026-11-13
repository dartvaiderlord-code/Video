import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/abordage/datagram_queue.dart';

void main() {
  test('zero send retries the identical datagram before following shards', () {
    var writable = false, interest = false;
    final sent = <int>[];
    final queue = DatagramSendQueue(
      send: (data) {
        if (!writable) return 0;
        sent.add(data.single);
        writable = false; // IOCP accepts one packet per write event.
        return data.length;
      },
      writeInterest: (value) => interest = value,
      nowMilliseconds: () => 0,
    );
    for (var i = 1; i <= 9; i++) {
      queue.add(Uint8List.fromList([i]));
    }
    expect(sent, isEmpty);
    expect(interest, true);
    for (var i = 0; i < 9; i++) {
      writable = true;
      queue.flush();
    }
    expect(sent, List.generate(9, (i) => i + 1));
    expect(queue.dropped, 0);
    expect(queue.queuedBytes, 0);
    expect(interest, false);
  });

  test('congestion is bounded by byte budget and age', () {
    var now = 0;
    final queue = DatagramSendQueue(
      send: (_) => 0,
      writeInterest: (_) {},
      nowMilliseconds: () => now,
      maxBytes: 4,
    );
    for (var i = 0; i < 3; i++) {
      queue.add(Uint8List(2));
    }
    expect(queue.queuedBytes, 4);
    expect(queue.dropped, 1);
    now = 121;
    queue.flush();
    expect(queue.queuedBytes, 0);
    expect(queue.dropped, 3);
  });
}
