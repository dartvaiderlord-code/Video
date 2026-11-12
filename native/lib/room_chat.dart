import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// A failed close must not leave the other tracks (especially microphone) active.
Future<void> releaseMedia(Future<void> Function() action) async {
  try {
    await action();
  } catch (_) {
    /* Continue releasing the remaining resources. */
  }
}

class ChatLine {
  ChatLine(this.name, this.text);
  final String name, text;
}

class _VoicePeer {
  _VoicePeer(this.pc);
  final RTCPeerConnection pc;
  final candidates = <RTCIceCandidate>[];
  bool ready = false;
}

/// Optional audio-only mesh, separate from the screen stream and its bitrate.
class RoomChat extends ChangeNotifier {
  RoomChat(this.send);
  final void Function(Map<String, dynamic>) send;
  final messages = <ChatLine>[];
  final _peers = <String, _VoicePeer>{};
  List<Map<String, dynamic>> members = [];
  List<dynamic> iceServers = [];
  String selfId = '';
  String error = '';
  MediaStream? _mic;
  bool enabled = false, muted = false, busy = false;
  int _generation = 0;

  void post(String text) {
    if (text.trim().isNotEmpty && text.trim().length <= 2000) {
      send({'type': 'chat', 'text': text.trim()});
    }
  }

  Future<void> toggleVoice() async {
    if (busy) return;
    if (enabled) {
      await leave();
      return;
    }
    busy = true;
    error = '';
    notifyListeners();
    final generation = _generation;
    try {
      final mic = await navigator.mediaDevices.getUserMedia({
        'video': false,
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
      });
      if (generation != _generation) {
        for (final t in mic.getTracks()) {
          await t.stop();
        }
        await mic.dispose();
        return;
      }
      _mic = mic;
      enabled = true;
      muted = false;
      send({'type': 'voice-state', 'enabled': true});
    } catch (e) {
      error = 'Микрофон недоступен: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _mic?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  Future<_VoicePeer> _peer(String id) async {
    if (_peers.containsKey(id)) return _peers[id]!;
    final generation = _generation;
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    if (!enabled || generation != _generation) {
      await pc.close();
      await pc.dispose();
      throw StateError('Голосовой чат отключён');
    }
    final peer = _VoicePeer(pc);
    _peers[id] = peer;
    pc.onIceCandidate = (c) {
      if (enabled && generation == _generation && c.candidate != null) {
        send({
          'type': 'voice-signal',
          'to': id,
          'data': {'candidate': c.toMap()},
        });
      }
    };
    // Native WebRTC plays remote audio; no video renderer (or microphone loopback).
    pc.onTrack = (event) {};
    pc.onConnectionState = (state) {
      if (enabled &&
          generation == _generation &&
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        error =
            'Не удалось подключить голос одного из участников. Проверьте TURN.';
        notifyListeners();
      }
    };
    for (final t in _mic!.getAudioTracks()) {
      await pc.addTrack(t, _mic!);
    }
    return peer;
  }

  Future<void> handle(Map<String, dynamic> msg) async {
    if (msg['type'] == 'chat') {
      messages.add(
        ChatLine(msg['name'] as String? ?? 'Матрос', msg['text'] as String),
      );
      if (messages.length > 100) messages.removeAt(0);
      notifyListeners();
    } else if (msg['type'] == 'members') {
      members = (msg['members'] as List)
          .map((m) => Map<String, dynamic>.from(m as Map))
          .toList();
      final active = members
          .where((m) => m['voice'] == true && m['id'] != selfId)
          .map((m) => m['id'] as String)
          .toSet();
      for (final id in _peers.keys.toList()) {
        if (!enabled || !active.contains(id)) {
          final p = _peers.remove(id)!;
          await p.pc.close();
          await p.pc.dispose();
        }
      }
      if (enabled) {
        for (final id in active) {
          if (selfId.compareTo(id) < 0 && !_peers.containsKey(id)) {
            final p = await _peer(id);
            await p.pc.setLocalDescription(await p.pc.createOffer());
            send({
              'type': 'voice-signal',
              'to': id,
              'data': {
                'description': (await p.pc.getLocalDescription())!.toMap(),
              },
            });
          }
        }
      }
      notifyListeners();
    } else if (msg['type'] == 'voice-signal' && enabled) {
      final id = msg['from'] as String;
      if (!members.any((m) => m['id'] == id && m['voice'] == true)) return;
      final p = await _peer(id);
      final data = msg['data'] as Map;
      if (data['description'] != null) {
        final d = data['description'] as Map;
        await p.pc.setRemoteDescription(
          RTCSessionDescription(d['sdp'] as String, d['type'] as String),
        );
        p.ready = true;
        for (final c in p.candidates) {
          await p.pc.addCandidate(c);
        }
        p.candidates.clear();
        if (d['type'] == 'offer') {
          await p.pc.setLocalDescription(await p.pc.createAnswer());
          send({
            'type': 'voice-signal',
            'to': id,
            'data': {
              'description': (await p.pc.getLocalDescription())!.toMap(),
            },
          });
        }
      }
      if (data['candidate'] != null) {
        final c = data['candidate'] as Map;
        final candidate = RTCIceCandidate(
          c['candidate'] as String?,
          c['sdpMid'] as String?,
          c['sdpMLineIndex'] as int?,
        );
        if (p.ready) {
          await p.pc.addCandidate(candidate);
        } else {
          p.candidates.add(candidate);
        }
      }
    }
  }

  Future<void> leave() async {
    _generation++;
    enabled = false;
    muted = false;
    send({'type': 'voice-state', 'enabled': false});
    final peers = _peers.values.toList();
    _peers.clear();
    for (final p in peers) {
      await releaseMedia(() => p.pc.close());
      await releaseMedia(() => p.pc.dispose());
    }
    final mic = _mic;
    _mic = null;
    for (final t in mic?.getTracks() ?? <MediaStreamTrack>[]) {
      await releaseMedia(() => t.stop());
    }
    await releaseMedia(() async {
      await mic?.dispose();
    });
    notifyListeners();
  }

  Future<void> reset() async {
    await leave();
    messages.clear();
    members = [];
    selfId = '';
    error = '';
    notifyListeners();
  }
}
