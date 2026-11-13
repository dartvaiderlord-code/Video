import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirate_tavern/abordage/encoder.dart';
import 'package:pirate_tavern/protocol.dart';
import 'package:pirate_tavern/abordage/playback_options.dart';

void main() {
  test('driver diagnostics retain required and available NVIDIA API', () {
    final failure = encoderDriverFailure(
      '[h264_nvenc @ 000001ab] Driver does not support the required nvenc '
      'API version. Required: 13.1 Found: 13.0',
    );
    expect(failure, contains('требует NVENC API 13.1'));
    expect(failure, contains('драйвер предоставляет 13.0'));
    expect(
      encoderDriverFailure('[AMF] DLL amfrt64.dll failed to open'),
      contains('библиотека драйвера'),
    );
    expect(encoderDriverFailure('Guessed Channel Layout: stereo'), isNull);
  });

  const profile = CaptureProfile(
    height: 1080,
    fps: 120,
    mbps: 50,
    codec: 'h264_nvenc',
  );
  test('direct GPU requires exact screen dimensions; conversion retains GPU', () {
    final exact = encoderAttempts(
      profile,
      'dxgi:0:0',
      sourceWidth: 1920,
      sourceHeight: 1080,
    );
    expect(exact.map((a) => a.processing), [
      CaptureProcessing.directGpu,
      CaptureProcessing.compatible,
    ]);
    expect(exact.map((a) => a.encoder), ['h264_nvenc', 'h264_nvenc']);
    for (final width in [null, 2560]) {
      final plans = encoderAttempts(
        profile,
        'dxgi:0:0',
        sourceWidth: width,
        sourceHeight: 1080,
      );
      expect(plans.map((a) => a.processing), [CaptureProcessing.compatible]);
    }
    final args = encoderArguments(profile, 'dxgi:0:0', 'h264_nvenc', 44000);
    expect(
      args.join(' '),
      contains(
        'hwdownload,format=bgra,scale=1920:1080:flags=fast_bilinear,format=nv12',
      ),
    );
    expect(args, containsAllInOrder(['-c:v', 'h264_nvenc', '-b:v', '50M']));
    expect(args.join(' '), contains('framerate=120'));
    expect(args.join(' '), isNot(contains('scale_d3d11')));
  });
  test('GPU auto never adds libx264 and QSV uses compatible NV12', () {
    const automatic = CaptureProfile(codec: 'auto');
    final plans = encoderAttempts(
      automatic,
      'dxgi:0:0',
      sourceWidth: 1920,
      sourceHeight: 1080,
    );
    expect(plans.map((a) => a.encoder), [
      'h264_nvenc',
      'h264_nvenc',
      'h264_amf',
      'h264_amf',
      'h264_qsv',
    ]);
    expect(plans.last.processing, CaptureProcessing.compatible);
    expect(
      encoderAttempts(
        const CaptureProfile(codec: 'libx264'),
        'dxgi:0:0',
      ).map((a) => a.encoder),
      ['libx264'],
    );
  });
  test(
    'audio command maps PCM and AAC without obsolete input queue option',
    () {
      const cpu = CaptureProfile(
        height: 1080,
        fps: 120,
        mbps: 50,
        codec: 'libx264',
      );
      final commands = <String, List<String>>{};
      for (final audio in [false, true]) {
        final args = encoderArguments(
          cpu,
          'dxgi:0:0',
          'libx264',
          44000,
          audioPort: audio ? 44001 : null,
        );
        expect(args, isNot(contains('-thread_queue_size')));
        if (audio) {
          expect(
            args,
            containsAllInOrder([
              '-f',
              's16le',
              '-ar',
              '48000',
              '-ac',
              '2',
              '-i',
            ]),
          );
          expect(
            args,
            containsAllInOrder(['-map', '1:a:0', '-c:v', 'libx264']),
          );
          expect(
            args,
            containsAllInOrder(['-c:a', 'aac', '-ar', '48000', '-b:a', '192k']),
          );
        } else {
          expect(args, contains('-an'));
        }
        commands[audio ? 'audio' : 'silent'] = args;
      }
      // CI feeds these exact production arguments to its bundled FFmpeg binary.
      final path = Platform.environment['ABORDAGE_FFMPEG_FIXTURE_DIR'];
      if (path != null) {
        Directory(path).createSync(recursive: true);
        File('$path/commands.json').writeAsStringSync(jsonEncode(commands));
        File('$path/player.json').writeAsStringSync(
          jsonEncode({
            'options': abordagePlaybackOptions,
            'url': abordagePlaybackUrl(44002),
          }),
        );
      }
    },
  );
  Future<File> fixture() async {
    final folder = await Directory.systemTemp.createTemp('abordage-encoder-');
    addTearDown(() => folder.delete(recursive: true));
    final file = File('${folder.path}/encoder.py');
    await file.writeAsString('''import sys,time
if sys.argv[1]=='wait':
    time.sleep(30)
elif 'hwdownload' not in ' '.join(sys.argv[2:]):
    print('Direct D3D11 input refused (80070057)',file=sys.stderr,flush=True)
    sys.exit(1)
else:
    print('frame=1\\nfps=120.0',flush=True)
    time.sleep(30)
''');
    return file;
  }

  test(
    'failed direct process retries compatible input on the same GPU',
    () async {
      final script = await fixture(), calls = <List<String>>[];
      final encoder = AbordageEncoder(
        executablePath: Platform.resolvedExecutable,
        displayInfoProvider: (_) async => {'width': 1920, 'height': 1080},
        startupWait: const Duration(seconds: 1),
        processStarter: (_, args) async {
          calls.add(args);
          return Process.start('python', [script.path, 'fallback', ...args]);
        },
      );
      try {
        await encoder.start(
          profile: profile,
          source: 'dxgi:0:0',
          port: 44000,
          onFailure: (message) => fail(message),
        );
        expect(calls.length, 2);
        for (final args in calls) {
          expect(args[args.indexOf('-c:v') + 1], 'h264_nvenc');
        }
        expect(calls.first.join(' '), isNot(contains('hwdownload')));
        expect(calls.last.join(' '), contains('hwdownload'));
        expect(encoder.selected, 'h264_nvenc');
        expect(encoder.processingPath, 'совместимая конвертация');
        expect(encoder.frames, 1);
        expect(encoder.encodingFps, 120);
      } finally {
        await encoder.stop();
      }
    },
  );
  test('stop during a failed attempt does not start another process', () async {
    final script = await fixture(), launched = Completer<void>();
    var calls = 0;
    final encoder = AbordageEncoder(
      executablePath: Platform.resolvedExecutable,
      displayInfoProvider: (_) async => {'width': 1920, 'height': 1080},
      startupWait: const Duration(seconds: 1),
      processStarter: (_, args) async {
        calls++;
        final process = await Process.start('python', [
          script.path,
          'wait',
          ...args,
        ]);
        launched.complete();
        return process;
      },
    );
    final start = encoder.start(
      profile: profile,
      source: 'dxgi:0:0',
      port: 44000,
      onFailure: (message) => fail(message),
    );
    await launched.future;
    await encoder.stop();
    await start;
    expect(calls, 1);
    expect(encoder.selected, isEmpty);
  });
}
