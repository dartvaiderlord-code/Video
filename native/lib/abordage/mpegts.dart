import 'dart:collection';
import 'dart:typed_data';

// Our MPEG-TS video PID is explicitly 256. Start only at a random-access PES;
// otherwise a late join can initialize a hardware decoder without SPS/PPS.
bool startsKeyframe(Uint8List ts) {
  for (var i = 0; i + 188 <= ts.length; i += 188) {
    if (ts[i] != 0x47 || (ts[i + 1] & 0x40) == 0) continue;
    final pid = ((ts[i + 1] & 0x1f) << 8) | ts[i + 2];
    if (pid == 256 &&
        (ts[i + 3] & 0x20) != 0 &&
        ts[i + 4] >= 1 &&
        (ts[i + 5] & 0x40) != 0) {
      return true;
    }
  }
  return false;
}

class TsJoinGate {
  bool ready = false;
  final _preroll = Queue<Uint8List>();
  List<Uint8List> push(Uint8List ts) {
    if (ready) return [ts];
    if (startsKeyframe(ts)) {
      ready = true;
      final result = [..._preroll, ts];
      _preroll.clear();
      return result;
    }
    _preroll.add(ts);
    while (_preroll.length > 2) {
      _preroll.removeFirst();
    }
    return [];
  }
}
