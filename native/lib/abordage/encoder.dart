import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../protocol.dart';

const encoderLabels = <String, String>{
  'auto': 'Авто · GPU',
  'h264_nvenc': 'NVIDIA · H.264',
  'h264_amf': 'AMD · H.264',
  'h264_qsv': 'Intel · H.264',
  'libx264': 'CPU · H.264',
};
const _audioChannel = MethodChannel('Pirate.Abordage.Audio');
List<String> encoderArguments(
  CaptureProfile p,
  String source,
  String encoder,
  int videoPort, {
  int? audioPort,
  int audioRate = 48000,
}) {
  final screen = source.startsWith('dxgi:');
  // The display index is recorded by our Windows display enumeration.
  final output = screen ? source.substring(5).split(':') : <String>[];
  if (screen &&
      (output.length < 2 ||
          int.tryParse(output[0]) == null ||
          int.tryParse(output[1]) == null)) {
    throw const FormatException('Неверный экран.');
  }
  if (!screen && !RegExp(r'^\d+$').hasMatch(source)) {
    throw const FormatException('Для Абордажа выберите экран или окно.');
  }
  final gpu = encoder == 'h264_nvenc' || encoder == 'h264_amf';
  final filter = screen && encoder == 'libx264'
      ? 'ddagrab=output_idx=${output[1]}:framerate=${p.fps}:dup_frames=1:draw_mouse=1,hwdownload,format=bgra,scale=${p.width}:${p.height}:flags=fast_bilinear,format=nv12'
      : screen
      ? 'ddagrab=output_idx=${output[1]}:framerate=${p.fps}:dup_frames=1:draw_mouse=1,scale_d3d11=width=${p.width}:height=${p.height}:format=nv12${gpu ? '' : ',hwdownload,format=nv12'}'
      : 'scale=${p.width}:${p.height}:flags=fast_bilinear,format=nv12';
  return [
    '-hide_banner',
    '-loglevel',
    'warning',
    '-nostdin',
    if (screen) ...[
      '-init_hw_device',
      'd3d11va=desktop:${output[0]}',
      '-filter_hw_device',
      'desktop',
      '-f',
      'lavfi',
      '-i',
      filter,
    ] else ...[
      '-f',
      'gdigrab',
      '-framerate',
      '${p.fps}',
      '-i',
      'hwnd=$source',
    ],
    if (audioPort != null) ...[
      '-thread_queue_size',
      '16',
      '-analyzeduration',
      '0',
      '-probesize',
      '32',
      '-f',
      's16le',
      '-ar',
      '$audioRate',
      '-ac',
      '2',
      '-i',
      'udp://127.0.0.1:$audioPort?localaddr=127.0.0.1&fifo_size=64&overrun_nonfatal=1',
    ],
    '-map',
    '0:v:0',
    if (audioPort != null) ...['-map', '1:a:0'],
    if (!screen) ...['-vf', filter],
    '-c:v',
    encoder,
    '-b:v',
    '${p.mbps}M',
    '-minrate',
    '${p.mbps}M',
    '-maxrate',
    '${p.mbps}M',
    '-bufsize',
    '${(p.mbps * 1000000 ~/ 20)}',
    '-g',
    '${(p.fps / 4).round()}',
    '-bf',
    '0',
    if (encoder == 'h264_nvenc') ...[
      '-preset',
      'p1',
      '-tune',
      'ull',
      '-rc',
      'cbr',
      '-rc-lookahead',
      '0',
      '-zerolatency',
      '1',
      '-delay',
      '0',
    ],
    if (encoder == 'h264_amf') ...[
      '-usage',
      'ultralowlatency',
      '-rc',
      'cbr',
      '-quality',
      'speed',
    ],
    if (encoder == 'h264_qsv') ...[
      '-preset',
      'veryfast',
      '-look_ahead',
      '0',
      '-async_depth',
      '1',
    ],
    if (encoder == 'libx264') ...[
      '-preset',
      'ultrafast',
      '-tune',
      'zerolatency',
      '-x264-params',
      'nal-hrd=cbr:force-cfr=1',
    ],
    '-fps_mode',
    'passthrough',
    '-flags:v',
    '+global_header',
    '-bsf:v',
    'dump_extra=freq=keyframe',
    if (audioPort != null) ...[
      '-c:a',
      'aac',
      '-ar',
      '48000',
      '-b:a',
      '192k',
    ] else
      '-an',
    '-progress',
    'pipe:1',
    '-stats_period',
    '1',
    '-mpegts_flags',
    '+resend_headers+pat_pmt_at_frames',
    '-mpegts_start_pid',
    '256',
    '-muxdelay',
    '0',
    '-muxpreload',
    '0',
    '-flush_packets',
    '1',
    '-f',
    'mpegts',
    'udp://127.0.0.1:$videoPort?pkt_size=1128&buffer_size=2097152&bitrate=${((p.mbps * 1.25 + 1) * 1000000).round()}&burst_bits=18048',
  ];
}

class AbordageEncoder {
  Process? _process;
  bool _stopping = false, _audio = false;
  String selected = '', lastError = '';
  int frames = 0;
  double encodingFps = 0;
  final _subscriptions = <StreamSubscription<String>>[];
  Future<void> start({
    required CaptureProfile profile,
    required String source,
    required int port,
    String? audioSource,
    required void Function(String) onFailure,
  }) async {
    final executable = File(
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}bin${Platform.pathSeparator}ffmpeg.exe',
    );
    if (!executable.existsSync()) {
      throw const FileSystemException(
        'В комплекте приложения отсутствует ffmpeg/bin/ffmpeg.exe. Распакуйте весь архив.',
      );
    }
    // Probe the selected device/codec. Auto never silently chooses software.
    final candidates = profile.codec == 'auto'
        ? ['h264_nvenc', 'h264_amf', 'h264_qsv']
        : [profile.codec];
    int? audioPort;
    var audioRate = 48000;
    if (audioSource != null) {
      final audio = await _audioChannel.invokeMapMethod<String, dynamic>(
        'start',
        {'source': audioSource},
      );
      audioPort = audio?['port'] as int?;
      audioRate = audio?['sampleRate'] as int? ?? 48000;
      if (audioPort == null) {
        throw StateError('Не удалось запустить выбранный звук.');
      }
      _audio = true;
      if (_stopping) {
        await stop();
        return;
      }
    }
    final failures = <String>[];
    for (final encoder in candidates) {
      if (_stopping) return;
      if (!encoderLabels.containsKey(encoder) || encoder == 'auto') continue;
      final process = await Process.start(
        executable.path,
        encoderArguments(
          profile,
          source,
          encoder,
          port,
          audioPort: audioPort,
          audioRate: audioRate,
        ),
      );
      _process = process;
      if (_stopping) {
        process.kill();
        await process.exitCode;
        return;
      }
      var emitted = false;
      _subscriptions.add(
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line.startsWith('fps=')) {
                encodingFps =
                    double.tryParse(line.substring(4).trim()) ?? encodingFps;
              }
              if (line.startsWith('frame=')) {
                frames = int.tryParse(line.substring(6).trim()) ?? frames;
                emitted = frames > 0;
              }
            }),
      );
      final errors = <String>[];
      _subscriptions.add(
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              errors.add(line);
              if (errors.length > 12) errors.removeAt(0);
              lastError = errors.join('\n');
            }),
      );
      final exited = await Future.any<int?>([
        process.exitCode,
        Future<int?>.delayed(const Duration(seconds: 3), () => null),
      ]);
      if (_stopping) return;
      if (exited == null && emitted) {
        selected = encoder;
        unawaited(
          process.exitCode.then((code) {
            if (!_stopping) {
              onFailure('Кодировщик остановлен ($code): $lastError');
            }
          }),
        );
        return;
      }
      process.kill();
      await process.exitCode;
      failures.add('$encoder: ${errors.join(' ')}');
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();
      frames = 0;
    }
    await stop();
    throw StateError(
      'Аппаратный кодировщик не запущен. Выберите GPU, на котором подключён экран, или явно CPU. ${failures.join('\n')}',
    );
  }

  Future<void> stop() async {
    _stopping = true;
    _process?.kill();
    if (_process != null) await _process!.exitCode;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    if (_audio) {
      try {
        await _audioChannel.invokeMethod<void>('stop');
      } catch (_) {}
      _audio = false;
    }
  }
}
