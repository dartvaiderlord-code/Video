Vendored from flutter_webrtc 1.6.3 (pub.dev). Upstream LICENSE and NOTICE retained.

Local changes:
- Independent audio.deviceId.exact selection for Windows display capture.
- Invalid/stale audio HWND fails closed, never falls back to system sound.
- Map Dart maintain-framerate-and-resolution to native MAINTAIN_FRAMERATE_AND_RESOLUTION (the SDK DISABLED enum maps to balanced).

All other plugin sources are upstream; example/tests omitted. Update deliberately,
retain these changes and run native and integration tests when upgrading.

- Windows DXGI Desktop Duplication sources (dxgi:adapter:output), bypass the SDK's
  hard >=60 FPS capture clamp. Frames scale preserving aspect ratio, rotate,
  compose the cursor, convert through pinned SIMD libyuv and enter the existing
  WebRTC source. Track disposal joins capture and stops loopback audio.
- Respect negotiated SDP bandwidth instead of the SDK legacy 512 kbps override.
- libyuv source/LICENSE/PATENTS are retained under third_party/libyuv.

1.2.2:
- SDK source enumeration captures new thumbnails even when get_thumbnail=false,
  and its factory retains the screen capturer/DXGI duplicator. A second
  DuplicateOutput may return E_INVALIDARG. Fall back to a free-threaded WGC
  frame pool on the same monitor, feeding the same I420/encoder pipeline.
- Keep the freshest WGC frame, handle cursor composition once, expose actual
  backend in track settings/stats, and report the exact initialization API.
- Enable standard exceptions for C++/WinRT; retain the old 30/60 FPS SDK path.
- Add an opt-in Windows probe which holds a duplicator and tests capture startup
  under that conflict; explicitly skip unsupported/headless runner desktops.
