#pragma once
#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "rtc_video_source.h"

namespace flutter_webrtc_plugin {
// DXGI Desktop Duplication -> SIMD I420 -> the existing WebRTC encoder.
// The upstream SDK desktop capture timer clamps every FPS >=60 to ~60.
class FastScreenCapture {
 public:
  static std::vector<std::pair<std::string, std::string>> Sources();
  ~FastScreenCapture();
  bool Start(const std::string& id, int fps, int max_width, int max_height,
             bool cursor,
             libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> source,
             std::string* error);
  void Stop();

 private:
  std::atomic<bool> running_{false};
  std::thread thread_;
};
}  // namespace flutter_webrtc_plugin
