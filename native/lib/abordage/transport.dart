import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'wire.dart';
import 'mpegts.dart';
import 'datagram_queue.dart';

class AbordageException implements Exception {
  AbordageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AbordageTransport {
  final _events = ReceivePort();
  final _workerErrors = ReceivePort();
  final _ready = Completer<int>();
  Isolate? _isolate;
  SendPort? _commands;
  bool _closed = false;
  Future<int> start(
    Map<String, dynamic> credentials, {
    required String host,
    required bool publish,
    int playbackPort = 0,
    required void Function(Map<String, dynamic>) onStats,
    required void Function(String) onFailure,
    void Function(List<int>)? onNack,
  }) async {
    _workerErrors.listen((dynamic error) {
      if (_closed) return;
      final message = 'Медиатранспорт остановлен: ${error ?? 'worker exited'}';
      if (!_ready.isCompleted) {
        _ready.completeError(AbordageException(message));
      } else {
        onFailure(message);
      }
    });
    _events.listen((dynamic value) {
      final m = Map<String, dynamic>.from(value as Map);
      switch (m['type']) {
        case 'control':
          _commands = m['port'] as SendPort?;
        case 'ready':
          if (!_ready.isCompleted) _ready.complete(m['port'] as int);
        case 'nack':
          if (!_closed) onNack?.call(List<int>.from(m['blocks'] as List));
        case 'stats':
          if (!_closed) onStats(m);
        case 'error':
          if (!_ready.isCompleted) {
            _ready.completeError(AbordageException(m['message'] as String));
          } else if (!_closed) {
            onFailure(m['message'] as String);
          }
      }
    });
    unawaited(
      Isolate.spawn(
            _worker,
            {
              'events': _events.sendPort,
              'credentials': credentials,
              'host': host,
              'publish': publish,
              'playbackPort': playbackPort,
            },
            onError: _workerErrors.sendPort,
            onExit: _workerErrors.sendPort,
          )
          .then((isolate) {
            _isolate = isolate;
            if (_closed) isolate.kill(priority: Isolate.immediate);
          })
          .catchError((Object error) {
            if (!_ready.isCompleted) _ready.completeError(error);
          }),
    );
    return _ready.future;
  }

  void retransmit(List<int> blocks) {
    if (!_closed) _commands?.send({'blocks': blocks});
  }

  Future<void> close() async {
    _closed = true;
    _commands?.send('stop');
    // Worker has no external resources beyond sockets. Kill also covers startup.
    _isolate?.kill(priority: Isolate.immediate);
    _events.close();
    _workerErrors.close();
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Сессия завершена.'));
    }
  }
}

Future<int> reserveLoopbackPort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  socket.close();
  return port;
}

void tuneUdp(RawDatagramSocket socket) {
  try {
    socket.setRawOption(
      RawSocketOption.fromInt(
        Platform.isWindows ? 0xffff : 1,
        Platform.isWindows ? 0x1002 : 8,
        2 * 1024 * 1024,
      ),
    );
    socket.setRawOption(
      RawSocketOption.fromInt(
        Platform.isWindows ? 0xffff : 1,
        Platform.isWindows ? 0x1001 : 7,
        2 * 1024 * 1024,
      ),
    );
  } catch (_) {
    /* OS limits do not change protocol correctness. */
  }
}

Future<void> _worker(Map<String, dynamic> config) async {
  final events = config['events'] as SendPort, commands = ReceivePort();
  events.send({'type': 'control', 'port': commands.sendPort});
  RawDatagramSocket? network, input, output;
  final timers = <Timer>[];
  var alive = true;
  void fail(Object error) {
    if (alive) events.send({'type': 'error', 'message': 'Абордаж: $error'});
  }

  try {
    final c = Map<String, dynamic>.from(config['credentials'] as Map);
    final id = unhex(c['id'] as String), key = unhex(c['key'] as String);
    final cipherKey = unhex(c['cipherKey'] as String),
        prefix = unhex(c['noncePrefix'] as String);
    if (id.length != 8 ||
        key.length != 32 ||
        cipherKey.length != 32 ||
        prefix.length != 20) {
      throw const FormatException('Неверные ключи транспорта.');
    }
    final cipher = BlockCipher(cipherKey, prefix),
        replay = ReplayWindow(),
        assembler = BlockAssembler();
    final addresses = await InternetAddress.lookup(
      c['host'] as String? ?? config['host'] as String,
      type: InternetAddressType.IPv4,
    );
    if (addresses.isEmpty) {
      throw const SocketException('Не найден IPv4 медиасервера.');
    }
    final server = addresses.first, port = c['port'] as int;
    network = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    tuneUdp(network);
    final socket = network;
    final publishing = config['publish'] as bool;
    if (publishing) {
      input = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      tuneUdp(input);
    }
    if (!publishing || (config['playbackPort'] as int) > 0) {
      output = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    final clock = Stopwatch()..start(), awaiting = Queue<(Uint8List, int)>();
    socket.writeEventsEnabled = false;
    final networkWrites = DatagramSendQueue(
      send: (packet) => socket.send(packet, server, port),
      writeInterest: (enabled) => socket.writeEventsEnabled = enabled,
      nowMilliseconds: () => clock.elapsedMilliseconds,
    );
    StreamSubscription<RawSocketEvent>? outputEvents;
    late final DatagramSendQueue? playbackWrites;
    playbackWrites = output == null
        ? null
        : DatagramSendQueue(
            send: (packet) => output!.send(
              packet,
              InternetAddress.loopbackIPv4,
              config['playbackPort'] as int,
            ),
            writeInterest: (enabled) {
              // Only register the outgoing local socket when it actually blocks.
              if (enabled && outputEvents == null) {
                output!.readEventsEnabled = false;
                output.writeEventsEnabled = false;
                outputEvents = output.listen((event) {
                  if (event == RawSocketEvent.write && alive) {
                    playbackWrites!.flush();
                  }
                });
              }
              output!.writeEventsEnabled = enabled;
            },
            nowMilliseconds: () => clock.elapsedMilliseconds,
          );
    void sendNetwork(Uint8List packet) {
      if (networkWrites.queuedBytes == 0 &&
          socket.send(packet, server, port) == packet.length) {
        return;
      }
      networkWrites.add(packet);
    }

    void sendPlayback(Uint8List packet) {
      if (playbackWrites!.queuedBytes == 0 &&
          output!.send(
                packet,
                InternetAddress.loopbackIPv4,
                config['playbackPort'] as int,
              ) ==
              packet.length) {
        return;
      }
      playbackWrites.add(packet);
    }

    final retransmitCache = <int, (Uint8List, int, int)>{};
    final stopped = Completer<void>();
    var retransmissions = 0, lastNackAt = -100;
    final pendingControls = <int>{};
    var sequence = 0,
        block = 0,
        ready = false,
        sending = false,
        receiving = false;
    var lastAck = 0, bytes = 0, packets = 0, dropped = 0, authFailures = 0;
    final pending = BytesBuilder(copy: false);
    var pendingSince = 0;
    final completed = Queue<ReadyBlock>();
    final joinGate = TsJoinGate();
    void sendControl(int kind) {
      try {
        final number = ++sequence;
        pendingControls.add(number);
        if (pendingControls.length > 16) {
          pendingControls.remove(pendingControls.first);
        }
        sendNetwork(makePacket(id: id, key: key, kind: kind, sequence: number));
      } catch (e) {
        fail(e);
        commands.sendPort.send('stop');
      }
    }

    void transmit(Uint8List encrypted, int number, int timestamp) {
      final shards = fragment(encrypted);
      for (var i = 0; i < shards.length; i++) {
        final packet = makePacket(
          id: id,
          key: key,
          kind: 3,
          sequence: ++sequence,
          block: number,
          timestamp: timestamp,
          index: i,
          count: shards.length - 1,
          length: encrypted.length,
          payload: shards[i],
        );
        sendNetwork(packet);
        packets++;
      }
    }

    commands.listen((dynamic command) {
      if (command == 'stop') {
        if (!stopped.isCompleted) stopped.complete();
        return;
      }
      if (command is Map && command['blocks'] is List) {
        for (final id in (command['blocks'] as List).take(4)) {
          final entry = retransmitCache[id];
          if (entry != null && clock.elapsedMilliseconds - entry.$3 < 250) {
            transmit(entry.$1, id as int, entry.$2);
            retransmissions++;
          }
        }
      }
    });
    Future<void> sendBlocks() async {
      if (sending || !alive) return;
      sending = true;
      try {
        while (awaiting.isNotEmpty && alive) {
          final item = awaiting.removeFirst();
          if (clock.elapsedMilliseconds - item.$2 > 120) {
            dropped++;
            continue;
          }
          final number = ++block;
          final encrypted = await cipher.seal(
            item.$1,
            number,
            item.$2 & 0xffffffff,
          );
          retransmitCache[number] = (
            encrypted,
            item.$2 & 0xffffffff,
            clock.elapsedMilliseconds,
          );
          retransmitCache.removeWhere(
            (_, entry) => clock.elapsedMilliseconds - entry.$3 > 250,
          );
          while (retransmitCache.length > 512) {
            retransmitCache.remove(retransmitCache.keys.first);
          }
          transmit(encrypted, number, item.$2 & 0xffffffff);
          bytes += item.$1.length;
        }
      } catch (e) {
        fail(e);
      } finally {
        sending = false;
      }
    }

    void enqueue(Uint8List ts, int timestamp) {
      // TS packets remain aligned even when congestion forces a whole block out.
      if (awaiting.length >= 128) {
        awaiting.removeFirst();
        dropped++;
      }
      awaiting.add((ts, timestamp));
      unawaited(sendBlocks());
    }

    void collect(Uint8List ts) {
      if (ts.isEmpty || ts.length % 188 != 0 || ts.length > 65536) return;
      if (pending.isEmpty) pendingSince = clock.elapsedMilliseconds;
      if (publishing && output != null) {
        for (final readyTs in joinGate.push(ts)) {
          sendPlayback(readyTs);
        }
      }
      pending.add(ts);
      if (pending.length >= maxPlaintext) {
        final all = pending.takeBytes();
        var offset = 0;
        while (all.length - offset >= maxPlaintext) {
          enqueue(
            Uint8List.sublistView(all, offset, offset + maxPlaintext),
            pendingSince,
          );
          offset += maxPlaintext;
        }
        if (offset < all.length) {
          pending.add(Uint8List.sublistView(all, offset));
          pendingSince = clock.elapsedMilliseconds;
        }
      }
    }

    Future<void> receiveBlocks() async {
      if (receiving || !alive) return;
      receiving = true;
      try {
        while (completed.isNotEmpty && alive) {
          final b = completed.removeFirst();
          try {
            final plain = await cipher.open(b.encrypted, b.id, b.timestamp);
            for (final readyTs in joinGate.push(plain)) {
              sendPlayback(readyTs);
            }
            bytes += plain.length;
          } catch (_) {
            authFailures++;
          }
        }
      } finally {
        receiving = false;
      }
    }

    network.listen((event) {
      if (event == RawSocketEvent.write && alive) networkWrites.flush();
      if (event != RawSocketEvent.read || !alive) return;
      final d = socket.receive();
      if (d == null) return;
      if (d.address.address != server.address || d.port != port) return;
      final p = WirePacket.parse(d.data, id, key);
      if (p == null) {
        authFailures++;
        return;
      }
      if ((p.kind == 2 || p.kind == 5) && pendingControls.remove(p.sequence)) {
        lastAck = clock.elapsedMilliseconds;
        if (!ready) {
          ready = true;
          events.send({'type': 'ready', 'port': input?.port ?? 0});
        }
      } else if (!publishing && p.kind == 3 && replay.accept(p.sequence)) {
        packets++;
        assembler.add(p, clock.elapsedMilliseconds);
      }

      for (final b in assembler.drain(clock.elapsedMilliseconds)) {
        if (completed.length >= 128) {
          completed.removeFirst();
          dropped++;
        }
        completed.add(b);
      }
      unawaited(receiveBlocks());
    });
    input?.listen((event) {
      if (event != RawSocketEvent.read || !alive) return;
      final d = input!.receive();
      if (d != null) collect(d.data);
    });
    timers.add(
      Timer.periodic(const Duration(milliseconds: 3), (_) {
        if (publishing &&
            pending.isNotEmpty &&
            clock.elapsedMilliseconds - pendingSince >= 3) {
          enqueue(pending.takeBytes(), pendingSince);
        }
        if (!publishing) {
          for (final b in assembler.drain(clock.elapsedMilliseconds)) {
            if (completed.length >= 128) {
              completed.removeFirst();
              dropped++;
            }
            completed.add(b);
          }
          final missing = clock.elapsedMilliseconds - lastNackAt >= 50
              ? assembler.missing(clock.elapsedMilliseconds)
              : <int>[];
          if (missing.isNotEmpty) lastNackAt = clock.elapsedMilliseconds;
          if (missing.isNotEmpty) {
            events.send({'type': 'nack', 'blocks': missing});
          }
          unawaited(receiveBlocks());
        }
      }),
    );
    timers.add(
      Timer.periodic(const Duration(seconds: 1), (_) {
        if (clock.elapsedMilliseconds - lastAck > 8000) {
          fail('UDP-порт $port недоступен. Откройте его на сервере.');
          alive = false;
          commands.sendPort.send('stop');
          return;
        }
        sendControl(ready ? 4 : 1);
        events.send({
          'type': 'stats',
          'bytes': bytes,
          'micros': clock.elapsedMicroseconds,
          'packets': packets,
          'dropped': dropped,
          'recovered': assembler.recovered,
          'lost': assembler.lost,
          'authFailures': authFailures,
          'sendFailures': networkWrites.dropped,
          'sendBlocked': networkWrites.blocked,
          'sendQueueBytes': networkWrites.queuedBytes,
          'playbackDrops': playbackWrites?.dropped ?? 0,
          'playbackBlocked': playbackWrites?.blocked ?? 0,
          'playbackQueueBytes': playbackWrites?.queuedBytes ?? 0,
          'waitingKeyframe': !joinGate.ready,
          'retransmissions': retransmissions,
        });
      }),
    );
    sendControl(1);
    await stopped.future;
  } catch (e) {
    fail(e);
  } finally {
    alive = false;
    for (final timer in timers) {
      timer.cancel();
    }
    network?.close();
    input?.close();
    output?.close();
    commands.close();
  }
}
