// Shared with the headless libmpv regression: exercise the actual player options.
const abordagePlaybackOptions = <String, String>{
  // media_kit opens Media through loadlist. libmpv otherwise rejects UDP as
  // unsafe in a playlist, even though this URL is generated on loopback only.
  'load-unsafe-playlists': 'yes',
  'cache': 'no',
  'demuxer-readahead-secs': '0',
  'demuxer-max-bytes': '1048576',
  'demuxer-lavf-probesize': '32768',
  'demuxer-lavf-analyzeduration': '0.5',
  'demuxer-lavf-o': 'fflags=+nobuffer',
  'vd-lavc-threads': '2',
  'vd-lavc-o': 'flags=+low_delay',
  'video-sync': 'audio',
  'framedrop': 'vo',
  'audio-buffer': '0.02',
};

String abordagePlaybackUrl(int port) =>
    'udp://127.0.0.1:$port?localaddr=127.0.0.1&fifo_size=8192&overrun_nonfatal=1&buffer_size=2097152&timeout=8000000';
