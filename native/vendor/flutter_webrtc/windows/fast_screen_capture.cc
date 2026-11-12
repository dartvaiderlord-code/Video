#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "fast_screen_capture.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <mmsystem.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <future>
#include <sstream>

#include "libyuv.h"
#include "rtc_video_frame.h"
using Microsoft::WRL::ComPtr;
namespace flutter_webrtc_plugin {
namespace {
std::string Failure(const char* operation, HRESULT hr) {
  std::ostringstream text;
  text << operation << " (HRESULT 0x" << std::hex
       << static_cast<unsigned long>(hr)
       << "). Use a local Windows desktop and an active monitor.";
  return text.str();
}
std::string Utf8(const wchar_t* wide) {
  int count =
      WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (count <= 1) return "Monitor";
  std::string value(static_cast<size_t>(count), 0);
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, value.data(), count, nullptr,
                      nullptr);
  value.pop_back();
  return value;
}
}  // namespace
std::vector<std::pair<std::string, std::string>> FastScreenCapture::Sources() {
  std::vector<std::pair<std::string, std::string>> sources;
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return sources;
  for (UINT a = 0;; a++) {
    ComPtr<IDXGIAdapter1> adapter;
    if (factory->EnumAdapters1(a, &adapter) == DXGI_ERROR_NOT_FOUND) break;
    if (!adapter) break;
    for (UINT o = 0;; o++) {
      ComPtr<IDXGIOutput> output;
      if (adapter->EnumOutputs(o, &output) == DXGI_ERROR_NOT_FOUND) break;
      if (!output) break;
      DXGI_OUTPUT_DESC desc{};
      if (SUCCEEDED(output->GetDesc(&desc)) && desc.AttachedToDesktop) {
        sources.emplace_back(
            "dxgi:" + std::to_string(a) + ":" + std::to_string(o),
            Utf8(desc.DeviceName) + " · DXGI 120–240 FPS");
      }
    }
  }
  return sources;
}
FastScreenCapture::~FastScreenCapture() { Stop(); }
void FastScreenCapture::Stop() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
}
bool FastScreenCapture::Start(
    const std::string& id, int fps, int max_width, int max_height, bool cursor,
    libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> source,
    std::string* error) {
  Stop();
  unsigned adapter_index = 0, output_index = 0;
  char extra = 0;
  if (sscanf_s(id.c_str(), "dxgi:%u:%u%c", &adapter_index, &output_index,
               &extra, 1) != 2 ||
      fps < 1 || fps > 240) {
    *error = "Invalid DXGI source/FPS";
    return false;
  }
  auto ready = std::make_shared<std::promise<std::string>>();
  auto future = ready->get_future();
  running_ = true;
  thread_ = std::thread([this, adapter_index, output_index, fps, max_width,
                         max_height, cursor, source, ready] {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    timeBeginPeriod(1);
    // RAII COM resources are confined to this thread; Stop joins before
    // teardown.
    bool announced = false;
    auto run = [&]() {
      ComPtr<IDXGIFactory1> factory;
      HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
      ComPtr<IDXGIAdapter1> adapter;
      if (SUCCEEDED(hr)) hr = factory->EnumAdapters1(adapter_index, &adapter);
      ComPtr<IDXGIOutput> output;
      if (SUCCEEDED(hr)) hr = adapter->EnumOutputs(output_index, &output);
      ComPtr<IDXGIOutput1> output1;
      if (SUCCEEDED(hr)) hr = output.As(&output1);
      DXGI_OUTPUT_DESC monitor{};
      if (SUCCEEDED(hr)) hr = output->GetDesc(&monitor);
      ComPtr<ID3D11Device> device;
      ComPtr<ID3D11DeviceContext> context;
      D3D_FEATURE_LEVEL level;
      if (SUCCEEDED(hr))
        hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                               D3D11_SDK_VERSION, &device, &level, &context);
      ComPtr<IDXGIOutputDuplication> duplication;
      if (SUCCEEDED(hr))
        hr = output1->DuplicateOutput(device.Get(), &duplication);
      if (FAILED(hr)) {
        ready->set_value(Failure("DXGI initialization", hr));
        return;
      }
      DXGI_OUTDUPL_DESC desc{};
      duplication->GetDesc(&desc);
      const bool quarter = desc.Rotation == DXGI_MODE_ROTATION_ROTATE90 ||
                           desc.Rotation == DXGI_MODE_ROTATION_ROTATE270;
      int source_width = static_cast<int>(desc.ModeDesc.Width),
          source_height = static_cast<int>(desc.ModeDesc.Height);
      const int rotated_width = quarter ? source_height : source_width,
                rotated_height = quarter ? source_width : source_height;
      double scale =
          std::min({1.0, static_cast<double>(max_width) / rotated_width,
                    static_cast<double>(max_height) / rotated_height});
      int width = std::max(2, static_cast<int>(rotated_width * scale) & ~1),
          height = std::max(2, static_cast<int>(rotated_height * scale) & ~1);
      D3D11_TEXTURE2D_DESC stage{};
      stage.Width = desc.ModeDesc.Width;
      stage.Height = desc.ModeDesc.Height;
      stage.MipLevels = 1;
      stage.ArraySize = 1;
      stage.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      stage.SampleDesc.Count = 1;
      stage.Usage = D3D11_USAGE_STAGING;
      stage.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      ComPtr<ID3D11Texture2D> staging;
      hr = device->CreateTexture2D(&stage, nullptr, &staging);
      if (FAILED(hr)) {
        ready->set_value(Failure("DXGI staging texture", hr));
        return;
      }
      BITMAPINFO bmi{};
      bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      bmi.bmiHeader.biWidth = width;
      bmi.bmiHeader.biHeight = -height;
      bmi.bmiHeader.biPlanes = 1;
      bmi.bmiHeader.biBitCount = 32;
      bmi.bmiHeader.biCompression = BI_RGB;
      void* pixels = nullptr;
      HDC dc = CreateCompatibleDC(nullptr);
      HBITMAP bitmap =
          CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &pixels, nullptr, 0);
      if (!dc || !bitmap || !pixels) {
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
        ready->set_value("Could not allocate DXGI frame buffer");
        return;
      }
      auto old_bitmap = SelectObject(dc, bitmap);
      std::vector<uint8_t> rotated(static_cast<size_t>(rotated_width) *
                                   rotated_height * 4);
      std::vector<uint8_t> y(static_cast<size_t>(width) * height),
          u(y.size() / 4), v(u.size());
      ready->set_value("");
      announced = true;
      const auto interval = std::chrono::nanoseconds(1000000000LL / fps);
      auto next = std::chrono::steady_clock::now();
      while (running_) {
        DXGI_OUTDUPL_FRAME_INFO info{};
        ComPtr<IDXGIResource> resource;
        hr = duplication->AcquireNextFrame(8, &info, &resource);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) continue;
        if (hr == DXGI_ERROR_ACCESS_LOST) {
          duplication.Reset();
          while (running_ && !duplication) {
            if (FAILED(output1->DuplicateOutput(device.Get(), &duplication)))
              std::this_thread::sleep_for(std::chrono::milliseconds(100));
          }
          if (!duplication) break;
          DXGI_OUTDUPL_DESC replacement{};
          duplication->GetDesc(&replacement);
          if (replacement.ModeDesc.Width != desc.ModeDesc.Width ||
              replacement.ModeDesc.Height != desc.ModeDesc.Height ||
              replacement.Rotation != desc.Rotation)
            break;
          continue;
        }
        if (FAILED(hr)) break;
        ComPtr<ID3D11Texture2D> texture;
        hr = resource.As(&texture);
        if (SUCCEEDED(hr)) context->CopyResource(staging.Get(), texture.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        if (SUCCEEDED(hr))
          hr = context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(hr)) {
          auto rotation = desc.Rotation == DXGI_MODE_ROTATION_ROTATE90
                              ? libyuv::kRotate90
                          : desc.Rotation == DXGI_MODE_ROTATION_ROTATE180
                              ? libyuv::kRotate180
                          : desc.Rotation == DXGI_MODE_ROTATION_ROTATE270
                              ? libyuv::kRotate270
                              : libyuv::kRotate0;
          libyuv::ARGBRotate(static_cast<const uint8_t*>(mapped.pData),
                             static_cast<int>(mapped.RowPitch), rotated.data(),
                             rotated_width * 4, source_width, source_height,
                             rotation);
          context->Unmap(staging.Get(), 0);
          libyuv::ARGBScale(rotated.data(), rotated_width * 4, rotated_width,
                            rotated_height, static_cast<uint8_t*>(pixels),
                            width * 4, width, height, libyuv::kFilterBilinear);
          if (cursor) {
            CURSORINFO ci{};
            ci.cbSize = sizeof(ci);
            if (GetCursorInfo(&ci) && ci.flags == CURSOR_SHOWING) {
              ICONINFO icon{};
              if (GetIconInfo(ci.hCursor, &icon)) {
                int x = static_cast<int>((ci.ptScreenPos.x -
                                          monitor.DesktopCoordinates.left -
                                          static_cast<LONG>(icon.xHotspot)) *
                                         scale);
                int cy = static_cast<int>((ci.ptScreenPos.y -
                                           monitor.DesktopCoordinates.top -
                                           static_cast<LONG>(icon.yHotspot)) *
                                          scale);
                DrawIconEx(
                    dc, x, cy, ci.hCursor,
                    static_cast<int>(GetSystemMetrics(SM_CXCURSOR) * scale),
                    static_cast<int>(GetSystemMetrics(SM_CYCURSOR) * scale), 0,
                    nullptr, DI_NORMAL);
                if (icon.hbmColor) DeleteObject(icon.hbmColor);
                if (icon.hbmMask) DeleteObject(icon.hbmMask);
              }
            }
          }
          libyuv::ARGBToI420(static_cast<uint8_t*>(pixels), width * 4, y.data(),
                             width, u.data(), width / 2, v.data(), width / 2,
                             width, height);
          source->OnCapturedFrame(libwebrtc::RTCVideoFrame::Create(
              width, height, y.data(), width, u.data(), width / 2, v.data(),
              width / 2));
        }
        duplication->ReleaseFrame();
        next += interval;
        auto now = std::chrono::steady_clock::now();
        if (next < now) next = now;
        std::this_thread::sleep_until(next);
      }
      SelectObject(dc, old_bitmap);
      DeleteObject(bitmap);
      DeleteDC(dc);
    };
    try {
      run();
    } catch (const std::exception& e) {
      if (!announced) ready->set_value(e.what());
    }
    running_ = false;
    timeEndPeriod(1);
    CoUninitialize();
  });
  *error = future.get();
  if (!error->empty()) {
    Stop();
    return false;
  }
  return true;
}
}  // namespace flutter_webrtc_plugin
