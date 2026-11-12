import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'protocol.dart';
import 'signaling.dart';

class _Peer {
  _Peer(this.pc);
  final RTCPeerConnection pc;
  final candidates = <RTCIceCandidate>[];
  bool remoteReady = false;
}

class TavernSession extends ChangeNotifier {
  final renderer = RTCVideoRenderer();
  final _peers = <String, _Peer>{};
  final _previousBytes = <String, (int, DateTime)>{};
  MediaStream? _capture;
  MediaStream? _remote;
  Signaling? _signaling;
  Timer? _stats;
  Future<void>? _initializing;
  List<dynamic> _iceServers = [];
  CaptureProfile _profile = const CaptureProfile();
  Uri? _origin;
  int _epoch = 0;
  bool _disposed = false;
  bool _stopping = false;
  bool busy = false;
  bool hosting = false;
  bool connected = false;
  bool hasVideo = false;
  bool playbackMuted = false;
  String status = 'Добро пожаловать на борт.';
  String invitation = '';
  String metrics = '';
  String warning = '';
  int get viewers => _peers.length;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= () async {
    await WebRTC.initialize(
      options: {
        'forceSWCodec': false,
        'zeroPlayoutDelay': true,
        if (Platform.isAndroid)
          'androidAudioConfiguration': AndroidAudioConfiguration.media.toMap(),
      },
    );
    await renderer.initialize();
  }();

  Future<List<DesktopCapturerSource>> sources() async {
    if (!Platform.isWindows) return [];
    await initialize();
    return desktopCapturer.getSources(
      types: [SourceType.Screen, SourceType.Window],
      thumbnailSize: ThumbnailSize(300, 180),
    );
  }

  Future<void> host(
    Uri origin,
    String code,
    DesktopCapturerSource source,
    CaptureProfile profile,
    Uint8List? trustedCa,
  ) async {
    if (!Platform.isWindows) {
      throw const FormatException('Трансляция доступна в Windows-клиенте.');
    }
    validateRoomCode(code);
    await stop();
    final epoch = _epoch;
    busy = true;
    hosting = true;
    _profile = profile;
    _origin = origin;
    status = 'Захватываем экран и системный звук…';
    _changed();
    try {
      await initialize();
      final capture = await navigator.mediaDevices.getDisplayMedia(
        profile.constraints(source.id),
      );
      if (epoch != _epoch) {
        for (final t in capture.getTracks()) {
          await t.stop();
        }
        await capture.dispose();
        return;
      }
      _capture = capture;
      for (final track in capture.getVideoTracks()) {
        track.onEnded = () {
          unawaited(stop('Захват экрана завершён системой.'));
        };
      }
      // The native texture renders video only; muting this local audio track would
      // also silence the WASAPI track sent to viewers.
      renderer.srcObject = capture;
      hasVideo = true;
      if (capture.getAudioTracks().isEmpty) {
        warning = 'Системный звук недоступен. Передаётся только изображение.';
      }
      await _connect(origin, trustedCa, {
        'type': 'create',
        'roomCode': validateRoomCode(code),
      }, epoch);
    } catch (e) {
      if (epoch == _epoch) await stop(_failure(e));
    }
  }

  Future<void> watch(
    RoomInvite invite,
    String code,
    Uint8List? trustedCa,
  ) async {
    validateRoomCode(code);
    await stop();
    final epoch = _epoch;
    busy = true;
    hosting = false;
    _origin = invite.server;
    status = 'Подключаемся к капитану…';
    _changed();
    try {
      await initialize();
      await _connect(invite.server, trustedCa, invite.join(code), epoch);
    } catch (e) {
      if (epoch == _epoch) await stop(_failure(e));
    }
  }

  String _failure(Object e) {
    if (e is HandshakeException) {
      return 'Сертификат не принят. Импортируйте root.crt этого сервера и сверьте отпечаток.';
    }
    if (e is SocketException || e is TimeoutException) {
      return 'Сервер недоступен. Проверьте адрес, порт и сеть.';
    }
    return 'Не удалось запустить сессию: $e';
  }

  Future<void> _connect(
    Uri origin,
    Uint8List? ca,
    Map<String, dynamic> first,
    int epoch,
  ) async {
    final signaling = Signaling();
    _signaling = signaling;
    await signaling.connect(
      origin: origin,
      trustedCa: ca,
      firstMessage: first,
      onMessage: (message) async {
        if (epoch == _epoch) await _handle(message, epoch);
      },
      onFailure: (message) {
        if (epoch == _epoch) unawaited(stop(message));
      },
    );
  }

  Future<_Peer> _newPeer(String id, int epoch) async {
    final pc = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });
    if (epoch != _epoch) {
      await pc.close();
      await pc.dispose();
      throw StateError('Сессия завершена.');
    }
    final peer = _Peer(pc);
    _peers[id] = peer;
    pc.onIceCandidate = (candidate) {
      if (epoch == _epoch && candidate.candidate != null) {
        _signaling?.send({
          'type': 'signal',
          'to': id,
          'data': {'candidate': candidate.toMap()},
        });
      }
    };
    pc.onConnectionState = (state) {
      if (epoch != _epoch) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        connected = true;
        busy = false;
        status = hosting
            ? 'Команда на связи · зрителей: $viewers'
            : 'Вы на борту. Прямая трансляция.';
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        status =
            'Медиасоединение не удалось. Проверьте TURN и исходящий канал.';
        busy = false;
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        status = 'Связь прервалась, ожидаем восстановления…';
      }
      _changed();
    };
    if (!hosting) {
      pc.onTrack = (event) {
        if (epoch != _epoch) return;
        if (event.streams.isNotEmpty) {
          _remote = event.streams.first;
          renderer.srcObject = _remote;
          hasVideo = true;
          _changed();
        }
      };
    }
    return peer;
  }

  Future<void> _handle(Map<String, dynamic> msg, int epoch) async {
    switch (msg['type']) {
      case 'error':
        await stop(msg['message'] as String? ?? 'Ошибка комнаты.');
      case 'ended':
        await stop('Капитан завершил трансляцию. Нужна новая ссылка.');
      case 'created':
        _iceServers = msg['iceServers'] as List<dynamic>;
        invitation = RoomInvite(
          _origin!,
          msg['room'] as String,
          msg['token'] as String,
        ).link;
        busy = false;
        connected = true;
        status = 'Комната открыта. Отправьте друзьям ссылку и код.';
        _startStats(epoch);
        _changed();
      case 'joined':
        _iceServers = msg['iceServers'] as List<dynamic>;
        await _newPeer('host', epoch);
        _startStats(epoch);
      case 'viewer-joined':
        final id = msg['id'] as String;
        try {
          final peer = await _newPeer(id, epoch);
          for (final track in _capture!.getTracks()) {
            await peer.pc.addTrack(track, _capture!);
          }
          await _preferCodec(peer.pc);
          await peer.pc.setLocalDescription(await peer.pc.createOffer());
          _signaling?.send({
            'type': 'signal',
            'to': id,
            'data': {
              'description': (await peer.pc.getLocalDescription())!.toMap(),
            },
          });
        } catch (_) {
          final peer = _peers.remove(id);
          await peer?.pc.close();
          await peer?.pc.dispose();
          warning = 'Не удалось подключить одного из зрителей.';
        }
        _changed();
      case 'viewer-left':
        final peer = _peers.remove(msg['id']);
        await peer?.pc.close();
        await peer?.pc.dispose();
        _changed();
      case 'signal':
        final peer = _peers[hosting ? msg['from'] : 'host'];
        if (peer == null) return;
        final data = Map<String, dynamic>.from(msg['data'] as Map);
        if (data['description'] != null) {
          final desc = Map<String, dynamic>.from(data['description'] as Map);
          await peer.pc.setRemoteDescription(
            RTCSessionDescription(
              desc['sdp'] as String?,
              desc['type'] as String?,
            ),
          );
          peer.remoteReady = true;
          for (final candidate in peer.candidates) {
            await peer.pc.addCandidate(candidate);
          }
          peer.candidates.clear();
          if (!hosting && desc['type'] == 'offer') {
            await peer.pc.setLocalDescription(await peer.pc.createAnswer());
            _signaling?.send({
              'type': 'signal',
              'data': {
                'description': (await peer.pc.getLocalDescription())!.toMap(),
              },
            });
          }
          if (hosting) await _setSenderQuality(peer.pc);
        }
        if (data['candidate'] != null) {
          final c = Map<String, dynamic>.from(data['candidate'] as Map);
          final candidate = RTCIceCandidate(
            c['candidate'] as String?,
            c['sdpMid'] as String?,
            c['sdpMLineIndex'] as int?,
          );
          if (peer.remoteReady) {
            await peer.pc.addCandidate(candidate);
          } else {
            peer.candidates.add(candidate);
          }
        }
    }
  }

  Future<void> _preferCodec(RTCPeerConnection pc) async {
    try {
      final capabilities = await getRtpSenderCapabilities('video');
      final codecs = capabilities.codecs ?? [];
      final preferred = codecs
          .where(
            (c) =>
                c.mimeType.toLowerCase() ==
                'video/${_profile.codec.toLowerCase()}',
          )
          .toList();
      if (preferred.isEmpty) {
        warning =
            '${_profile.codec} недоступен, используем согласованный кодек.';
        return;
      }
      final ordered = [
        ...preferred,
        ...codecs.where((c) => !preferred.contains(c)),
      ];
      for (final t in await pc.getTransceivers()) {
        if (t.sender.track?.kind == 'video') {
          await t.setCodecPreferences(ordered);
        }
      }
    } catch (_) {
      warning =
          'Выбор кодека не поддержан, используется автоматическое согласование.';
    }
  }

  Future<void> _setSenderQuality(RTCPeerConnection pc) async {
    for (final sender in await pc.getSenders()) {
      if (sender.track?.kind != 'video') continue;
      final p = sender.parameters;
      p.encodings ??= [RTCRtpEncoding()];
      if (p.encodings!.isEmpty) p.encodings!.add(RTCRtpEncoding());
      for (final e in p.encodings!) {
        e.maxBitrate = _profile.mbps * 1000000;
        e.maxFramerate = _profile.fps;
      }
      p.degradationPreference = _profile.keepResolution
          ? RTCDegradationPreference.MAINTAIN_RESOLUTION
          : RTCDegradationPreference.MAINTAIN_FRAMERATE;
      try {
        if (!await sender.setParameters(p)) {
          warning = 'Кодек не принял ограничения качества.';
        }
      } catch (_) {
        warning =
            'Параметры качества отклонены кодеком; проверьте фактическую статистику.';
      }
    }
    _changed();
  }

  void _startStats(int epoch) {
    bool running = false;
    _stats = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (epoch != _epoch || running) return;
      running = true;
      try {
        final lines = <String>[];
        int index = 0;
        for (final entry in _peers.entries.toList()) {
          final reports = await entry.value.pc.getStats();
          final byId = {for (final r in reports) r.id: r};
          for (final r in reports) {
            final v = r.values;
            if ((r.type == 'outbound-rtp' && hosting ||
                    r.type == 'inbound-rtp' && !hosting) &&
                (v['kind'] == 'video' || v['mediaType'] == 'video')) {
              final bytes =
                  (v[hosting ? 'bytesSent' : 'bytesReceived'] as num?)
                      ?.toInt() ??
                  0;
              final key = '${entry.key}:${r.id}', now = DateTime.now();
              final prev = _previousBytes[key];
              _previousBytes[key] = (bytes, now);
              final rate = prev == null
                  ? 0.0
                  : (bytes - prev.$1) *
                        8 /
                        now.difference(prev.$2).inMicroseconds;
              final codec = byId[v['codecId']]?.values['mimeType'] ?? 'кодек —';
              final impl =
                  v[hosting
                      ? 'encoderImplementation'
                      : 'decoderImplementation'];
              lines.add(
                '${hosting ? 'Зритель ${++index}' : 'Видео'}: ${v['frameWidth'] ?? '—'}×${v['frameHeight'] ?? '—'} · ${v['framesPerSecond'] ?? '—'} FPS · ${rate.toStringAsFixed(1)} Мбит/с · $codec${impl == null ? '' : ' · $impl'}${v['qualityLimitationReason'] == null ? '' : ' · ограничение: ${v['qualityLimitationReason']}'}',
              );
            }
            if (r.type == 'candidate-pair' &&
                v['state'] == 'succeeded' &&
                (v['nominated'] == true || v['selected'] == true)) {
              final local = byId[v['localCandidateId']]?.values,
                  remote = byId[v['remoteCandidateId']]?.values;
              final relay =
                  local?['candidateType'] == 'relay' ||
                  remote?['candidateType'] == 'relay';
              final rtt = (v['currentRoundTripTime'] as num?);
              lines.add(
                '${relay ? 'TURN' : 'Прямое соединение'}${rtt == null ? '' : ' · RTT ${(rtt * 1000).round()} мс'}',
              );
            }
          }
        }
        if (epoch == _epoch) {
          metrics = lines.join('\n');
          _changed();
        }
      } catch (_) {
        /* Some native builds expose a smaller stats set. */
      } finally {
        running = false;
      }
    });
  }

  Future<void> toggleAudio() async {
    final tracks = _remote?.getAudioTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    playbackMuted = !playbackMuted;
    for (final track in tracks) {
      await Helper.setVolume(playbackMuted ? 0.0 : 1.0, track);
    }
    _changed();
  }

  Future<void> stop([String? message]) async {
    if (_stopping) return;
    _stopping = true;
    _epoch++;
    _stats?.cancel();
    final signaling = _signaling;
    _signaling = null;
    final peers = _peers.values.toList();
    _peers.clear();
    final capture = _capture, remote = _remote;
    _capture = null;
    _remote = null;
    if (renderer.textureId != null) renderer.srcObject = null;
    try {
      await signaling?.close();
      for (final p in peers) {
        await p.pc.close();
        await p.pc.dispose();
      }
      for (final t in capture?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await capture?.dispose();
      await remote?.dispose();
    } finally {
      busy = false;
      connected = false;
      hosting = false;
      hasVideo = false;
      playbackMuted = false;
      invitation = '';
      metrics = '';
      warning = '';
      _previousBytes.clear();
      if (message != null) status = message;
      _stopping = false;
      _changed();
    }
  }

  Future<void> shutdown() async {
    _disposed = true;
    await stop();
    if (_initializing != null) {
      try {
        await _initializing;
        await renderer.dispose();
      } catch (_) {}
    }
    super.dispose();
  }
}
