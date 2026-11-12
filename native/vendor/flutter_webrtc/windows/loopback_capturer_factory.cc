#ifdef _WIN32

#include "application_loopback_capturer.h"

namespace flutter_webrtc_plugin {

// ---------------------------------------------------------------------------
// CreateLoopbackCapturer — Windows factory implementation
// Creates an ApplicationLoopbackCapturer and, if source_id refers to a window
// (identified by its HWND as a decimal string), sets the target PID so that
// only that application's audio is captured. "0" explicitly selects system
// audio. An invalid/stale window must never silently expose all system audio.
// ---------------------------------------------------------------------------
std::unique_ptr<LoopbackCapturer> CreateLoopbackCapturer(
    const std::string& source_id) {
  auto cap = std::make_unique<ApplicationLoopbackCapturer>();
  if (source_id != "0") {
    try {
      HWND hwnd = reinterpret_cast<HWND>(
          static_cast<uintptr_t>(std::stoull(source_id)));
      if (hwnd && IsWindow(hwnd)) {
        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid != 0) {
          cap->SetTargetProcessId(pid);
          return cap;
        }
      }
    } catch (...) {
      // Invalid selection: fail closed.
    }
    return nullptr;
  }
  return cap;
}

}  // namespace flutter_webrtc_plugin

#endif  // _WIN32
