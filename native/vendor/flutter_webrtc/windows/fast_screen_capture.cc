#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "fast_screen_capture.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <mmsystem.h>
#include <roapi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>
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
       << static_cast<unsigned long>(hr) << ").";
  return text.str();
}
struct DibBuffer {
  HDC dc = nullptr;
  HBITMAP bitmap = nullptr;
  HGDIOBJ previous = nullptr;
  ~DibBuffer() {
    if (dc && previous) SelectObject(dc, previous);
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
  }
};
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
            Utf8(desc.DeviceName) + " · DXGI/WGC 120–240 FPS");
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
  backend_ = 0;
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
    const HRESULT apartment = RoInitialize(RO_INIT_MULTITHREADED);
    if (FAILED(apartment)) {
      ready->set_value(Failure("RoInitialize", apartment));
      running_ = false;
      return;
    }
    timeBeginPeriod(1);
    // RAII COM resources are confined to this thread; Stop joins before
    // teardown.
    bool announced = false;
    auto run = [&]() {
      using namespace winrt::Windows::Graphics::Capture;
      using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
      using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
      const char* operation = "CreateDXGIFactory1";
      ComPtr<IDXGIFactory1> factory;
      HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
      ComPtr<IDXGIAdapter1> adapter;
      if (SUCCEEDED(hr)) {
        operation = "EnumAdapters1";
        hr = factory->EnumAdapters1(adapter_index, &adapter);
      }
      ComPtr<IDXGIOutput> output;
      if (SUCCEEDED(hr)) {
        operation = "EnumOutputs";
        hr = adapter->EnumOutputs(output_index, &output);
      }
      ComPtr<IDXGIOutput1> output1;
      if (SUCCEEDED(hr)) {
        operation = "QueryInterface IDXGIOutput1";
        hr = output.As(&output1);
      }
      DXGI_OUTPUT_DESC monitor{};
      if (SUCCEEDED(hr)) {
        operation = "IDXGIOutput GetDesc";
        hr = output->GetDesc(&monitor);
      }
      ComPtr<ID3D11Device> device;
      ComPtr<ID3D11DeviceContext> context;
      D3D_FEATURE_LEVEL level;
      if (SUCCEEDED(hr)) {
        operation = "D3D11CreateDevice";
        hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                               D3D11_SDK_VERSION, &device, &level, &context);
        if (FAILED(hr)) {
          // WGC can capture the chosen monitor through the default hardware GPU
          // too (hybrid laptops); never silently switch to a software renderer.
          hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                 D3D11_SDK_VERSION, &device, &level, &context);
        }
      }
      if (FAILED(hr)) {
        ready->set_value(Failure(operation, hr));
        return;
      }
      ComPtr<IDXGIOutputDuplication> duplication;
      hr = output1->DuplicateOutput(device.Get(), &duplication);
      const HRESULT duplication_error = hr;
      Direct3D11CaptureFramePool frame_pool{nullptr};
      GraphicsCaptureSession capture_session{nullptr};
      GraphicsCaptureItem capture_item{nullptr};
      IDirect3DDevice capture_device{nullptr};
      DXGI_OUTDUPL_DESC desc{};
      bool cursor_in_frame = false;
      if (SUCCEEDED(hr)) {
        duplication->GetDesc(&desc);
        backend_ = 1;
      } else {
        // The SDK's source picker captures thumbnails even with
        // thumbnails=false and retains its DXGI duplicator. A second
        // DuplicateOutput in the same process then returns E_INVALIDARG. WGC
        // has no such singleton conflict and keeps the requested
        // capture/encoder FPS; no 60 FPS fallback.
        try {
          operation = "GraphicsCaptureSession IsSupported";
          if (!GraphicsCaptureSession::IsSupported())
            winrt::throw_hresult(E_NOTIMPL);
          operation = "CreateForMonitor";
          auto interop =
              winrt::get_activation_factory<GraphicsCaptureItem,
                                            IGraphicsCaptureItemInterop>();
          winrt::check_hresult(interop->CreateForMonitor(
              monitor.Monitor, winrt::guid_of<GraphicsCaptureItem>(),
              winrt::put_abi(capture_item)));
          operation = "CreateDirect3D11DeviceFromDXGIDevice";
          ComPtr<IDXGIDevice> dxgi_device;
          winrt::check_hresult(device.As(&dxgi_device));
          ComPtr<IInspectable> inspectable;
          winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
              dxgi_device.Get(), &inspectable));
          winrt::check_hresult(
              inspectable->QueryInterface(winrt::guid_of<IDirect3DDevice>(),
                                          winrt::put_abi(capture_device)));
          auto size = capture_item.Size();
          operation = "Direct3D11CaptureFramePool CreateFreeThreaded";
          frame_pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
              capture_device, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2,
              size);
          capture_session = frame_pool.CreateCaptureSession(capture_item);
          if (winrt::Windows::Foundation::Metadata::ApiInformation::
                  IsPropertyPresent(
                      L"Windows.Graphics.Capture.GraphicsCaptureSession",
                      L"IsCursorCaptureEnabled")) {
            capture_session.IsCursorCaptureEnabled(cursor);
          }
          cursor_in_frame = true;
          operation = "GraphicsCaptureSession StartCapture";
          capture_session.StartCapture();
          backend_ = 2;
          // WGC surfaces are already rotated into desktop coordinates.
          desc.ModeDesc.Width = static_cast<UINT>(size.Width);
          desc.ModeDesc.Height = static_cast<UINT>(size.Height);
          desc.Rotation = DXGI_MODE_ROTATION_IDENTITY;
        } catch (const winrt::hresult_error& e) {
          ready->set_value(
              Failure("IDXGIOutput1 DuplicateOutput", duplication_error) +
              " Fallback WGC: " + Failure(operation, e.code()) + " " +
              winrt::to_string(e.message()));
          return;
        }
      }
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
      DibBuffer dib;
      dib.dc = CreateCompatibleDC(nullptr);
      HDC dc = dib.dc;
      dib.bitmap =
          CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &pixels, nullptr, 0);
      HBITMAP bitmap = dib.bitmap;
      if (!dc || !bitmap || !pixels) {
        ready->set_value("Could not allocate DXGI frame buffer");
        return;
      }
      dib.previous = SelectObject(dc, bitmap);
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
        Direct3D11CaptureFrame wgc_frame{nullptr};
        ComPtr<ID3D11Texture2D> texture;
        if (frame_pool) {
          wgc_frame = frame_pool.TryGetNextFrame();
          if (!wgc_frame) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
          }
          // Keep the newest buffered frame to avoid adding capture-queue delay.
          while (auto newer = frame_pool.TryGetNextFrame()) {
            wgc_frame.Close();
            wgc_frame = std::move(newer);
          }
          auto access = wgc_frame.Surface()
                            .as<Windows::Graphics::DirectX::Direct3D11::
                                    IDirect3DDxgiInterfaceAccess>();
          hr = access->GetInterface(IID_PPV_ARGS(&texture));
        } else {
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
          hr = resource.As(&texture);
        }
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
          if (cursor && !cursor_in_frame) {
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
        if (wgc_frame)
          wgc_frame.Close();
        else
          duplication->ReleaseFrame();
        next += interval;
        auto now = std::chrono::steady_clock::now();
        if (next < now) next = now;
        std::this_thread::sleep_until(next);
      }
      if (capture_session) capture_session.Close();
      if (frame_pool) frame_pool.Close();
    };
    try {
      run();
    } catch (const winrt::hresult_error& e) {
      if (!announced) ready->set_value(Failure("WGC capture", e.code()));
    } catch (const std::exception& e) {
      if (!announced) ready->set_value(e.what());
    }
    running_ = false;
    timeEndPeriod(1);
    RoUninitialize();
  });
  *error = future.get();
  if (!error->empty()) {
    Stop();
    return false;
  }
  return true;
}
}  // namespace flutter_webrtc_plugin
