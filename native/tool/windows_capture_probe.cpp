// Real Windows capture regression. Discard frames in memory; no
// networking/files.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <d3d11.h>
#include <dxgi1_2.h>
#include <windows.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <thread>

#include "base/refcount.h"
#include "fast_screen_capture.h"
using Microsoft::WRL::ComPtr;
using namespace libwebrtc;
using flutter_webrtc_plugin::FastScreenCapture;
class ProbeSource : public RTCVideoSource {
 public:
  std::atomic<int> frames{0};
  void OnCapturedFrame(scoped_refptr<RTCVideoFrame> frame) override {
    if (frame && frame->width() > 0 && frame->height() > 0 && frame->DataY())
      frames++;
  }
  SourceType GetSourceType() const override { return SourceType::kCustom; }
  void AddProcessor(RTCVideoProcessor*) override {}
  void RemoveProcessor(RTCVideoProcessor*) override {}
};
int main() {
  const auto sources = FastScreenCapture::Sources();
  if (sources.empty()) {
    std::cout << "::notice::SKIP Windows capture probe: no active monitor on "
                 "runner.\n";
    return 0;
  }
  unsigned a = 0, o = 0;
  sscanf_s(sources[0].first.c_str(), "dxgi:%u:%u", &a, &o);
  ComPtr<IDXGIFactory1> factory;
  HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  ComPtr<IDXGIAdapter1> adapter;
  if (SUCCEEDED(hr)) hr = factory->EnumAdapters1(a, &adapter);
  ComPtr<IDXGIOutput> output;
  if (SUCCEEDED(hr)) hr = adapter->EnumOutputs(o, &output);
  ComPtr<IDXGIOutput1> output1;
  if (SUCCEEDED(hr)) hr = output.As(&output1);
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  D3D_FEATURE_LEVEL level;
  if (SUCCEEDED(hr))
    hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                           D3D11_SDK_VERSION, &device, &level, &context);
  ComPtr<IDXGIOutputDuplication> thumbnail_capture;
  if (SUCCEEDED(hr))
    hr = output1->DuplicateOutput(device.Get(), &thumbnail_capture);
  if (FAILED(hr)) {
    std::cout << "::notice::SKIP Windows capture probe: runner desktop "
                 "duplication unavailable, HRESULT 0x"
              << std::hex << static_cast<unsigned long>(hr) << ".\n";
    return 0;
  }
  // Reproduce the SDK picker retaining its first per-process duplicator.
  auto source = scoped_refptr<ProbeSource>(new RefCountedObject<ProbeSource>());
  FastScreenCapture capture;
  std::string error;
  if (!capture.Start(sources[0].first, 120, 640, 360, false, source, &error)) {
    if (error.find("0x80004001") != std::string::npos ||
        error.find("0x80070005") != std::string::npos ||
        error.find("0x80040154") != std::string::npos) {
      std::cout << "::notice::SKIP Windows capture probe: WGC unavailable in "
                   "runner session. "
                << error << "\n";
      return 0;
    }
    std::cerr << "::error::Capture conflict regression: " << error << "\n";
    return 1;
  }
  auto until = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (source->frames == 0 && std::chrono::steady_clock::now() < until)
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  capture.Stop();
  if (source->frames == 0) {
    std::cerr << "::error::Capture initialized but delivered no I420 frame.\n";
    return 1;
  }
  std::cout
      << "::notice::PASS Windows capture probe: retained duplicator, backend="
      << capture.backend() << ", frames=" << source->frames.load()
      << ". This checks capture startup, not 1080p/120 performance.\n";
  return 0;
}
