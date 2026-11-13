#include <winsock2.h>
#include <ws2tcpip.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <sstream>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include "application_loopback_capturer.h"
#include "libwebrtc.h"
#include <memory>
#include <string>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
class PcmSocketSource : public libwebrtc::RTCAudioSource {
 public:
  SOCKET socket_ = INVALID_SOCKET;
  sockaddr_in destination_{};
  ~PcmSocketSource() override { if(socket_!=INVALID_SOCKET) closesocket(socket_); }
  void CaptureFrame(const void* data, int bits, int rate, size_t channels, size_t frames) override {
    if(bits==16 && rate>0 && channels==2 && socket_!=INVALID_SOCKET)
      sendto(socket_,static_cast<const char*>(data),static_cast<int>(frames*channels*2),0,reinterpret_cast<sockaddr*>(&destination_),sizeof(destination_));
  }
  SourceType GetSourceType() const override { return kCustom; }
};
class AbordageAudio : public flutter::Plugin {
 public:
  explicit AbordageAudio(flutter::PluginRegistrarWindows* registrar) {
    WSADATA data{}; network_ok_ = WSAStartup(MAKEWORD(2,2),&data)==0;
    channel_=std::make_unique<flutter::MethodChannel<EncodableValue>>(registrar->messenger(),"Pirate.Abordage.Audio",&flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      if(call.method_name()=="displayInfo") {
        const auto* args=std::get_if<EncodableMap>(call.arguments());
        const auto item=args ? args->find(EncodableValue("source")) : EncodableMap::const_iterator{};
        if(!args || item==args->end() || !std::holds_alternative<std::string>(item->second)) {result->Error("display","Select a display");return;}
        const auto source=std::get<std::string>(item->second);
        unsigned adapter_index=0,output_index=0;char separator=0;
        std::istringstream indices(source.size()>=5 ? source.substr(5) : std::string());
        if(source.rfind("dxgi:",0)!=0 || !(indices>>adapter_index>>separator>>output_index) || separator!=':' || !indices.eof() || adapter_index>64 || output_index>64) {result->Error("display","Invalid display");return;}
        Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
        Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
        Microsoft::WRL::ComPtr<IDXGIOutput> output;
        DXGI_OUTPUT_DESC desc{};
        HRESULT hr=CreateDXGIFactory1(IID_PPV_ARGS(&factory));
        if(SUCCEEDED(hr)) hr=factory->EnumAdapters1(adapter_index,&adapter);
        if(SUCCEEDED(hr)) hr=adapter->EnumOutputs(output_index,&output);
        if(SUCCEEDED(hr)) hr=output->GetDesc(&desc);
        if(FAILED(hr)) {result->Error("display","Display information unavailable");return;}
        result->Success(EncodableValue(EncodableMap{
          {EncodableValue("width"),EncodableValue(static_cast<int>(desc.DesktopCoordinates.right-desc.DesktopCoordinates.left))},
          {EncodableValue("height"),EncodableValue(static_cast<int>(desc.DesktopCoordinates.bottom-desc.DesktopCoordinates.top))}}));
        return;
      }
      if(call.method_name()=="stop") {Stop();result->Success();return;}
      if(call.method_name()!="start") {result->NotImplemented();return;}
      Stop();
      if(!network_ok_) {result->Error("network","Windows sockets unavailable");return;}
      const auto* args=std::get_if<EncodableMap>(call.arguments());
      const auto item=args ? args->find(EncodableValue("source")) : EncodableMap::const_iterator{};
      if(!args || item==args->end() || !std::holds_alternative<std::string>(item->second)) {result->Error("source","Select an audio source");return;}
      const auto source=std::get<std::string>(item->second);
      auto capture=std::make_unique<flutter_webrtc_plugin::ApplicationLoopbackCapturer>();
      capture->SetTransportMode();
      if(source!="0") {
        try {
          HWND hwnd=reinterpret_cast<HWND>(static_cast<uintptr_t>(std::stoull(source)));
          DWORD pid=0;if(IsWindow(hwnd)) GetWindowThreadProcessId(hwnd,&pid);
          if(pid==0) {result->Error("source","Selected application closed");return;}
          capture->SetTargetProcessId(pid);
        } catch(...) {result->Error("source","Invalid application");return;}
      }
      auto sink=libwebrtc::scoped_refptr<PcmSocketSource>(new libwebrtc::RefCountedObject<PcmSocketSource>());
      sink->socket_=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
      if(sink->socket_==INVALID_SOCKET) {result->Error("socket","Cannot create audio socket");return;}
      sockaddr_in local{};local.sin_family=AF_INET;local.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
      SOCKET reservation=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
      int length=sizeof(local);
      if(reservation==INVALID_SOCKET || bind(reservation,reinterpret_cast<sockaddr*>(&local),sizeof(local)) || getsockname(reservation,reinterpret_cast<sockaddr*>(&local),&length)) {
        if(reservation!=INVALID_SOCKET) closesocket(reservation);
        result->Error("socket","Cannot allocate local audio port");return;
      }
      closesocket(reservation);sink->destination_=local;
      if(!capture->Start(sink)) {result->Error("capture","Selected WASAPI source unavailable");return;}
      const int rate=capture->sample_rate();
      capture_=std::move(capture);sink_=sink;
      result->Success(EncodableValue(EncodableMap{{EncodableValue("port"),EncodableValue(static_cast<int>(ntohs(local.sin_port)))},{EncodableValue("sampleRate"),EncodableValue(rate)}}));
    });
  }
  ~AbordageAudio() override {Stop();if(network_ok_) WSACleanup();}
  void Stop() {if(capture_) capture_->Stop();capture_.reset();sink_=nullptr;}
 private:
  bool network_ok_=false;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter_webrtc_plugin::ApplicationLoopbackCapturer> capture_;
  libwebrtc::scoped_refptr<PcmSocketSource> sink_;
};
}
void RegisterAbordageAudio(flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<AbordageAudio>(registrar));
}
