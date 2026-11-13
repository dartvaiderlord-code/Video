import 'dart:async';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'playback_options.dart';

class AbordagePlayback {
  AbordagePlayback() {
    MediaKit.ensureInitialized();
    player = Player(
      configuration: const PlayerConfiguration(bufferSize: 1024 * 1024),
    );
    controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: Platform.isAndroid ? 'mediacodec' : 'd3d11va',
        enableHardwareAcceleration: true,
      ),
    );
  }
  late final Player player;
  late final VideoController controller;
  StreamSubscription<String>? _errors;
  Timer? _firstFrame;
  bool _stopped = false, _rendered = false;
  String lastError = '';
  Future<void> open(int port, void Function(String) onFailure) async {
    _firstFrame = Timer(const Duration(seconds: 12), () {
      if (!_stopped && !_rendered) {
        onFailure('Абордаж: декодер не показал кадр. $lastError');
      }
    });
    unawaited(
      controller.waitUntilFirstFrameRendered
          .then((_) {
            _rendered = true;
            _firstFrame?.cancel();
          })
          .catchError((Object error) {
            if (!_stopped) onFailure('Видеовывод Абордажа: $error');
          }),
    );
    final native = player.platform as NativePlayer;
    for (final option in abordagePlaybackOptions.entries) {
      await native.setProperty(option.key, option.value);
    }
    _errors = player.stream.error.listen(
      (error) =>
          lastError = error.length > 512 ? error.substring(0, 512) : error,
    );
    await player.open(Media(abordagePlaybackUrl(port)));
  }

  Future<Map<String, String>> stats() async {
    final native = player.platform as NativePlayer;
    final result = <String, String>{};
    for (final name in [
      'estimated-vf-fps',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'hwdec-current',
      'video-codec',
      'video-dec-params',
      'avsync',
      'video-pts',
    ]) {
      try {
        result[name] = await native.getProperty(name);
      } catch (_) {}
    }
    result['size'] =
        '${player.state.width ?? '—'}×${player.state.height ?? '—'}';
    return result;
  }

  Future<void> stop() async {
    _stopped = true;
    _firstFrame?.cancel();
    await _errors?.cancel();
    await player.dispose();
  }
}
