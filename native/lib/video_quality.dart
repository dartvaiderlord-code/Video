import 'protocol.dart';

/// Negotiate the same budget in offer AND answer, not only sender encodings.
/// Keep codec profile/packetization, audio, RTX and transport attributes intact.
String videoQualitySdp(String sdp, CaptureProfile profile) {
  final kbps = profile.mbps * 1000;
  return sdp.split(RegExp(r'(?=^m=)', multiLine: true)).map((section) {
    if (!section.startsWith('m=video ') || section.startsWith('m=video 0 ')) {
      return section;
    }
    final lines = section
        .trimRight()
        .split(RegExp(r'\r?\n'))
        .where(
          (l) =>
              !RegExp(r'^b=(AS|TIAS):').hasMatch(l) &&
              !l.startsWith('a=framerate:'),
        )
        .toList();
    final at = lines.indexWhere((l) => l.startsWith('c='));
    lines.insertAll(at < 0 ? 1 : at + 1, [
      'b=AS:$kbps',
      'b=TIAS:${kbps * 1000}',
    ]);
    final payloads = lines
        .map(
          (l) => RegExp(
            r'^a=rtpmap:(\d+) (VP8|VP9|H264|AV1)/',
            caseSensitive: false,
          ).firstMatch(l)?.group(1),
        )
        .whereType<String>()
        .toList();
    for (final pt in payloads) {
      final prefix = 'a=fmtp:$pt ';
      final index = lines.indexWhere((l) => l.startsWith(prefix));
      final params =
          (index < 0
                  ? <String>[]
                  : lines[index].substring(prefix.length).split(';'))
              .map((p) => p.trim())
              .where(
                (p) =>
                    p.isNotEmpty &&
                    !RegExp(
                      r'^x-google-(min|max|start)-bitrate=',
                      caseSensitive: false,
                    ).hasMatch(p),
              )
              .toList();
      params.addAll([
        'x-google-start-bitrate=${(kbps * .8).round()}',
        'x-google-min-bitrate=${profile.fullQuality ? (kbps * .6).round() : 0}',
        'x-google-max-bitrate=$kbps',
      ]);
      if (index < 0) {
        lines.add(prefix + params.join(';'));
      } else {
        lines[index] = prefix + params.join(';');
      }
    }
    lines.add('a=framerate:${profile.fps}');
    return '${lines.join('\r\n')}\r\n';
  }).join();
}

CaptureProfile? videoBudget(String sdp) {
  final sections = sdp
      .split(RegExp(r'(?=^m=)', multiLine: true))
      .where((s) => s.startsWith('m=video '));
  if (sections.isEmpty) return null;
  final section = sections.first;
  final bps =
      int.tryParse(
        RegExp(
              r'^b=TIAS:(\d+)',
              multiLine: true,
            ).firstMatch(section)?.group(1) ??
            '',
      ) ??
      (int.tryParse(
                RegExp(
                      r'^b=AS:(\d+)',
                      multiLine: true,
                    ).firstMatch(section)?.group(1) ??
                    '',
              ) ??
              0) *
          1000;
  if (bps <= 0) return null;
  final fps =
      int.tryParse(
        RegExp(
              r'^a=framerate:(\d+)',
              multiLine: true,
            ).firstMatch(section)?.group(1) ??
            '',
      ) ??
      60;
  return CaptureProfile(
    mbps: (bps / 1000000).round().clamp(1, 200),
    fps: fps.clamp(1, 240),
  );
}
