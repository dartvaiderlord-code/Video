// Headless loopback regression for the exact desktop libwebrtc shipped by the
// plugin. Synthetic I420 frames exercise encoding, RTP and decoding, not
// capture hardware. No external STUN/TURN or network service is used.
#include <atomic>
#include <chrono>
#include <future>
#include <iostream>
#include <regex>
#include <sstream>
#include <thread>
#include <vector>

#include "libwebrtc.h"
#include "rtc_peerconnection.h"
using namespace libwebrtc;
using Clock = std::chrono::steady_clock;

struct Observer : RTCPeerConnectionObserver {
  scoped_refptr<RTCPeerConnection> other;
  void OnSignalingState(RTCSignalingState) override {}
  void OnPeerConnectionState(RTCPeerConnectionState) override {}
  void OnIceGatheringState(RTCIceGatheringState) override {}
  void OnIceConnectionState(RTCIceConnectionState) override {}
  void OnIceCandidate(scoped_refptr<RTCIceCandidate> c) override {
    if (other)
      other->AddCandidate(c->sdp_mid(), c->sdp_mline_index(), c->candidate());
  }
  void OnAddStream(scoped_refptr<RTCMediaStream>) override {}
  void OnRemoveStream(scoped_refptr<RTCMediaStream>) override {}
  void OnDataChannel(scoped_refptr<RTCDataChannel>) override {}
  void OnRenegotiationNeeded() override {}
  void OnTrack(scoped_refptr<RTCRtpTransceiver>) override {}
  void OnAddTrack(vector<scoped_refptr<RTCMediaStream>>,
                  scoped_refptr<RTCRtpReceiver>) override {}
  void OnRemoveTrack(scoped_refptr<RTCRtpReceiver>) override {}
};
template <class T>
T wait(std::future<T> f) {
  if (f.wait_for(std::chrono::seconds(15)) != std::future_status::ready)
    throw std::runtime_error("WebRTC operation timed out");
  return f.get();
}
std::string description(scoped_refptr<RTCPeerConnection> pc, bool offer) {
  auto p = std::make_shared<std::promise<std::string>>();
  auto f = p->get_future();
  auto ok = [p](const string sdp, const string) {
    p->set_value(sdp.std_string());
  };
  auto fail = [p](const char* e) {
    p->set_exception(std::make_exception_ptr(std::runtime_error(e)));
  };
  if (offer)
    pc->CreateOffer(ok, fail, RTCMediaConstraints::Create());
  else
    pc->CreateAnswer(ok, fail, RTCMediaConstraints::Create());
  return wait(std::move(f));
}
void set(scoped_refptr<RTCPeerConnection> pc, bool local,
         const std::string& sdp, const char* type) {
  auto p = std::make_shared<std::promise<bool>>();
  auto f = p->get_future();
  auto ok = [p]() { p->set_value(true); };
  auto fail = [p](const char* e) {
    p->set_exception(std::make_exception_ptr(std::runtime_error(e)));
  };
  if (local)
    pc->SetLocalDescription(sdp, type, ok, fail);
  else
    pc->SetRemoteDescription(sdp, type, ok, fail);
  wait(std::move(f));
}
std::string quality(std::string sdp, int mbps, int fps) {
  const auto at = sdp.find("m=video ");
  if (at == std::string::npos) throw std::runtime_error("No video SDP");
  std::string prefix = sdp.substr(0, at), video = sdp.substr(at);
  video = std::regex_replace(video, std::regex("b=(AS|TIAS):[0-9]+\\r\\n"), "");
  auto pos = video.find("\r\n", video.find("c="));
  video.insert(pos + 2, "b=AS:" + std::to_string(mbps * 1000) + "\r\nb=TIAS:" +
                            std::to_string(mbps * 1000000) + "\r\n");
  std::regex r("a=rtpmap:([0-9]+) (VP8|VP9|H264|AV1)/");
  std::vector<std::string> pts;
  for (auto i = std::sregex_iterator(video.begin(), video.end(), r);
       i != std::sregex_iterator(); ++i)
    pts.push_back((*i)[1]);
  for (const auto& pt : pts) {
    const auto start = video.find("a=fmtp:" + pt + " ");
    std::string params =
        "x-google-min-bitrate=" + std::to_string(mbps * 600) +
        ";x-google-start-bitrate=" + std::to_string(mbps * 800) +
        ";x-google-max-bitrate=" + std::to_string(mbps * 1000);
    if (start == std::string::npos)
      video += "a=fmtp:" + pt + " " + params + "\r\n";
    else
      video.insert(video.find("\r\n", start), ";" + params);
  }
  return prefix + video + "a=framerate:" + std::to_string(fps) + "\r\n";
}
std::string stats(scoped_refptr<RTCPeerConnection> pc) {
  auto p = std::make_shared<std::promise<std::string>>();
  auto f = p->get_future();
  pc->GetStats(
      [p](const vector<scoped_refptr<MediaRTCStats>> reports) {
        std::string out;
        for (auto r : reports.std_vector()) {
          if (r->type().std_string() == "outbound-rtp" ||
              r->type().std_string() == "inbound-rtp")
            out += r->ToJson().std_string() + "\n";
        }
        p->set_value(out);
      },
      [p](const char* e) {
        p->set_exception(std::make_exception_ptr(std::runtime_error(e)));
      });
  return wait(std::move(f));
}
uint64_t value(const std::string& s, const std::string& field) {
  std::smatch m;
  return std::regex_search(s, m,
                           std::regex("\"" + field + "\"\\s*:\\s*([0-9]+)"))
             ? std::stoull(m[1])
             : 0;
}
int main(int argc, char** argv) {
  try {
    const bool patched = argc < 2 || std::string(argv[1]) != "baseline";
    const int fps = argc > 2 ? std::stoi(argv[2]) : 120,
              width = argc > 3 ? std::stoi(argv[3]) : 640,
              height = width * 9 / 16;
    const int mbps = width <= 320 ? 12 : 35;
    if (fps < 1 || fps > 240 || width < 160 || width > 3840 || width % 32)
      throw std::runtime_error("Invalid benchmark FPS/width");
    std::cerr << "initialize\n";
    LibWebRTC::Initialize();
    auto factory = LibWebRTC::CreateRTCPeerConnectionFactory();
    std::cerr << "factory\n";
    if (!factory->Initialize()) throw std::runtime_error("Factory init failed");
    std::cerr << "peers\n";
    RTCConfiguration config;
    config.local_video_bandwidth = 0;
    auto a = factory->Create(config, RTCMediaConstraints::Create()),
         b = factory->Create(config, RTCMediaConstraints::Create());
    if (!a || !b) throw std::runtime_error("Peer creation failed");
    std::cerr << "source\n";
    Observer ao, bo;
    ao.other = b;
    bo.other = a;
    a->RegisterRTCPeerConnectionObserver(&ao);
    b->RegisterRTCPeerConnectionObserver(&bo);
    auto source = factory->CreateCustomVideoSource(
        "benchmark", RTCMediaConstraints::Create());
    if (!source) throw std::runtime_error("Source creation failed");
    std::cerr << "track\n";
    auto track = factory->CreateVideoTrack(source, "video");
    vector<string> ids(std::vector<string>{"benchmark"});
    auto sender = a->AddTrack(track, ids);
    std::cerr << "offer\n";
    auto offer = description(a, true);
    if (patched) offer = quality(offer, mbps, fps);
    set(a, true, offer, "offer");
    set(b, false, offer, "offer");
    std::cerr << "answer\n";
    auto answer = description(b, false);
    if (patched) answer = quality(answer, mbps, fps);
    set(b, true, answer, "answer");
    set(a, false, answer, "answer");
    std::cerr << "parameters\n";
    auto p = sender->parameters();
    auto encodings = p->encodings();
    for (auto e : encodings.std_vector()) {
      e->set_max_bitrate_bps(mbps * 1000000);
      e->set_max_framerate(fps);
      e->set_scale_resolution_down_by(1);
      if (patched) e->set_min_bitrate_bps(mbps * 600000);
    }
    p->set_encodings(encodings);
    p->SetDegradationPreference(
        patched ? RTCDegradationPreference::MAINTAIN_FRAMERATE_AND_RESOLUTION
                : RTCDegradationPreference::MAINTAIN_RESOLUTION);
    if (!sender->set_parameters(p))
      throw std::runtime_error("Sender rejected parameters");
    std::cerr << "frames\n";
    std::atomic<bool> running{true};
    std::thread feed([&] {
      std::vector<uint8_t> y(width * height), u(width * height / 4, 128), v(u);
      uint32_t seed = 1;
      auto next = Clock::now();
      while (running) {
        for (auto& px : y) {
          seed = seed * 1664525 + 1013904223;
          px = 16 + (seed >> 24) % 220;
        }
        source->OnCapturedFrame(
            RTCVideoFrame::Create(width, height, y.data(), width, u.data(),
                                  width / 2, v.data(), width / 2));
        next += std::chrono::microseconds(1000000 / fps);
        std::this_thread::sleep_until(next);
      }
    });
    std::this_thread::sleep_for(std::chrono::seconds(5));
    auto sa = stats(a), sb = stats(b);
    auto start = Clock::now();
    std::this_thread::sleep_for(std::chrono::seconds(8));
    auto ea = stats(a), eb = stats(b);
    auto seconds = std::chrono::duration<double>(Clock::now() - start).count();
    running = false;
    feed.join();
    double sent = (value(ea, "bytesSent") - value(sa, "bytesSent")) * 8 /
                  seconds / 1000000;
    double received =
        (value(eb, "bytesReceived") - value(sb, "bytesReceived")) * 8 /
        seconds / 1000000;
    double decoded =
        (value(eb, "framesDecoded") - value(sb, "framesDecoded")) / seconds;
    std::cout << (patched ? "quality" : "baseline") << " sent_Mbps=" << sent
              << " received_Mbps=" << received << " decoded_FPS=" << decoded
              << "\n"
              << ea << eb << std::flush;
    a->Close();
    b->Close();
    a->DeRegisterRTCPeerConnectionObserver();
    b->DeRegisterRTCPeerConnectionObserver();
    ao.other = nullptr;
    bo.other = nullptr;
    factory->Delete(a);
    factory->Delete(b);
    // SDK thread teardown is performed by process exit after all media stops.
    return patched && (sent < 5 || received < 5 || decoded < fps * .75) ? 1 : 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << std::endl;
    return 2;
  }
}
