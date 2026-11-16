import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final child = await Process.start(args[0], [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    '-re',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=64x64:rate=30',
    '-progress',
    'pipe:1',
    '-stats_period',
    '0.1',
    '-f',
    'null',
    '-',
  ]);
  await child.stdin.close();
  unawaited(child.stderr.drain<void>());
  var announced = false;
  child.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    if (!announced &&
        line.startsWith('frame=') &&
        (int.tryParse(line.substring(6).trim()) ?? 0) > 0) {
      announced = true;
      File('${args[1]}.tmp').writeAsStringSync('${child.pid}', flush: true);
      File('${args[1]}.tmp').renameSync(args[1]);
    }
  });
  await child.exitCode;
}
