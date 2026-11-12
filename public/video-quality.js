// Negotiate the budget in both directions. Sender maxBitrate alone does not
// replace WebRTC's codec/default (often 2.5 Mbps) bandwidth configuration.
export function videoBudget(sdp) {
  const section = sdp.split(/(?=^m=)/m).find(s => s.startsWith('m=video '));
  if (!section) return null;
  const bps = Number(section.match(/^b=TIAS:(\d+)/m)?.[1]) || Number(section.match(/^b=AS:(\d+)/m)?.[1]) * 1000;
  const fps = Number(section.match(/^a=framerate:(\d+)/m)?.[1]) || 60;
  return bps > 0 ? {mbps: Math.min(200, Math.max(1, bps / 1000000)), fps: Math.min(240, Math.max(1, fps))} : null;
}
export function videoQualitySdp(sdp, {mbps, fps, fullQuality = true}) {
  if (!(mbps >= 1 && mbps <= 200 && fps >= 1 && fps <= 240)) throw new Error('Invalid video budget');
  const kbps = Math.round(mbps * 1000);
  return sdp.split(/(?=^m=)/m).map(section => {
    if (!section.startsWith('m=video ') || section.startsWith('m=video 0 ')) return section;
    const lines = section.trimEnd().split(/\r?\n/).filter(l => !/^b=(AS|TIAS):/.test(l) && !l.startsWith('a=framerate:'));
    const at = lines.findIndex(l => l.startsWith('c='));
    lines.splice(at < 0 ? 1 : at + 1, 0, `b=AS:${kbps}`, `b=TIAS:${kbps * 1000}`);
    const payloads = lines.filter(l => /^a=rtpmap:\d+ (VP8|VP9|H264|AV1)\//i.test(l)).map(l => l.match(/^a=rtpmap:(\d+)/)[1]);
    for (const pt of payloads) {
      const prefix = `a=fmtp:${pt} `;
      const index = lines.findIndex(l => l.startsWith(prefix));
      const params = (index < 0 ? [] : lines[index].slice(prefix.length).split(';')).map(p => p.trim()).filter(p => p && !/^x-google-(min|max|start)-bitrate=/i.test(p));
      params.push(`x-google-start-bitrate=${Math.round(kbps * .8)}`, `x-google-min-bitrate=${fullQuality ? Math.round(kbps * .6) : 0}`, `x-google-max-bitrate=${kbps}`);
      const line = prefix + params.join(';');
      if (index < 0) lines.push(line); else lines[index] = line;
    }
    lines.push(`a=framerate:${fps}`);
    return lines.join('\r\n') + '\r\n';
  }).join('');
}
