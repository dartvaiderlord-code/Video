import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pirate_tavern/abordage/playback_options.dart';
import 'package:pirate_tavern/abordage/transport.dart';

void main() {
  final library = Platform.environment['ABORDAGE_PLAYER_LIBRARY'];
  final ffmpeg = Platform.environment['ABORDAGE_PLAYER_FFMPEG'];
  test(
    'real media_kit Player.open rejects UDP without permission, then decodes it',
    () async {
      MediaKit.ensureInitialized(libmpv: library!);
      final logs = <String>[];
      Future<Player> create({required bool allowPlaylist}) async {
        final player = Player(
          configuration: const PlayerConfiguration(
            vo: 'null',
            bufferSize: 1024 * 1024,
            logLevel: MPVLogLevel.warn,
          ),
        );
        final native = player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await native.setProperty('hwdec', 'no');
        // VideoController normally enables this; the headless test has no texture.
        await native.setProperty('vid', 'auto');
        for (final entry in abordagePlaybackOptions.entries) {
          if (!allowPlaylist && entry.key == 'load-unsafe-playlists') continue;
          await native.setProperty(entry.key, entry.value);
        }
        return player;
      }

      // Negative control uses the previous application options and the actual
      // public Player.open API. It must report libmpv's specific refusal.
      final blocked = await create(allowPlaylist: false);
      final refused = blocked.stream.log.firstWhere(
        (entry) =>
            entry.text.contains('Refusing to load potentially unsafe URL'),
      );
      try {
        await blocked.open(
          Media(abordagePlaybackUrl(await reserveLoopbackPort())),
        );
        await refused.timeout(const Duration(seconds: 6));
        expect(blocked.state.width, isNull);
      } finally {
        await blocked.dispose();
      }

      final player = await create(allowPlaylist: true);
      final subscription = player.stream.log.listen((entry) {
        logs.add('${entry.level}: ${entry.text}');
        if (logs.length > 20) logs.removeAt(0);
      });
      Process? encoder;
      try {
        final port = await reserveLoopbackPort();
        final video = player.stream.videoParams.firstWhere(
          (value) => value.dw == 320,
        );
        final opening = player.open(Media(abordagePlaybackUrl(port)));
        encoder = await Process.start(ffmpeg!, [
          '-hide_banner',
          '-loglevel',
          'error',
          '-nostdin',
          '-re',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=320x180:rate=240',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=1000:sample_rate=48000',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-tune',
          'zerolatency',
          '-pix_fmt',
          'yuv420p',
          '-b:v',
          '25M',
          '-g',
          '30',
          '-bf',
          '0',
          '-c:a',
          'aac',
          '-ac',
          '2',
          '-ar',
          '48000',
          '-mpegts_flags',
          '+resend_headers+pat_pmt_at_frames',
          '-muxdelay',
          '0',
          '-muxpreload',
          '0',
          '-flush_packets',
          '1',
          '-f',
          'mpegts',
          'udp://127.0.0.1:$port?pkt_size=1128',
        ]);
        unawaited(encoder.stdout.drain<void>());
        unawaited(encoder.stderr.drain<void>());
        await encoder.stdin.close();
        await opening.timeout(const Duration(seconds: 6));
        await video.timeout(
          const Duration(seconds: 8),
          onTimeout: () {
            throw StateError(
              'Player.open produced no video: ${logs.join('\n')}',
            );
          },
        );
        final native = player.platform as NativePlayer;
        final deadline = DateTime.now().add(const Duration(seconds: 4));
        while (await native.getProperty('vo-configured') != 'yes' &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(
          await native.getProperty('vo-configured'),
          'yes',
          reason: logs.join('\n'),
        );
        expect(await native.getProperty('video-out-params/w'), '320');
        expect(await native.getProperty('audio-params/samplerate'), '48000');
      } finally {
        encoder?.kill(ProcessSignal.sigkill);
        if (encoder != null) await encoder.exitCode;
        await subscription.cancel();
        await player.dispose();
      }
    },
    skip: library == null || ffmpeg == null
        ? 'CI runs this integration after bundling its actual libmpv and FFmpeg'
        : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
