#include <atomic>
#include <chrono>
#include <cstring>
#include <condition_variable>
#include <mutex>
#include <regex>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <thread>
#include <vector>
#include "peercast.h"
#include "usys.h"
#include "channel.h"
#include "servmgr.h"
#include "stats.h"
#include "external_traffic.h"
#include "pcp.h"
#include "yplist.h"
#include "json.hpp"
#ifdef __ANDROID__
#include <android/log.h>
#include <sys/system_properties.h>
#endif
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#define EXPORT extern "C" __attribute__((visibility("default")))
namespace {
// Match the app runtime check without trusting a caller-supplied bypass flag.
// This permits receiving on virtual devices; it never claims an open port.
bool isEmulator() {
#if defined(__ANDROID__)
  char hardware[PROP_VALUE_MAX] = {};
  char fingerprint[PROP_VALUE_MAX] = {};
  __system_property_get("ro.hardware", hardware);
  __system_property_get("ro.build.fingerprint", fingerprint);
  return std::strcmp(hardware, "goldfish") == 0 ||
         std::strcmp(hardware, "ranchu") == 0 ||
         std::strncmp(fingerprint, "generic/sdk", 11) == 0 ||
         std::strncmp(fingerprint, "google/sdk_gphone", sizeof("google/sdk_gphone") - 1) == 0;
#elif defined(__APPLE__) && TARGET_OS_SIMULATOR
  return true;
#else
  return false;
#endif
}
std::recursive_mutex apiMutex;
std::mutex requestMutex;
std::mutex connectionErrorMutex;
std::string connectionError;
std::string activeId, lastError, directory;
std::atomic<bool> running{false}, relaysAllowed{false};
std::atomic<int> portState{0}; // 0 unknown, 1 externally verified, 2 failed
std::atomic<bool> checkingPort{false};
std::chrono::steady_clock::time_point portCheckStarted;
std::mutex probeMutex;
std::shared_ptr<ClientSocket> probeSocket;
ThreadInfo probeThread;
std::string probeTracker, probeChannelId, portCheckError;

class MobileSys final : public USys {
 public:
  std::mutex mutex;
  std::condition_variable changed;
  int workers = 0;
  bool startWaitableThread(ThreadInfo* info) override {
    { std::lock_guard<std::mutex> g(mutex); ++workers; }
    info->m_active = true;
    try {
      info->handle = std::thread([this, info] {
        try { info->func(info); }
        catch (const std::exception& e) { LOG_ERROR("Mobile worker: %s", e.what()); }
        catch (...) { LOG_ERROR("Mobile worker failed"); }
        { std::lock_guard<std::mutex> g(mutex); --workers; }
        changed.notify_all();
      });
      return true;
    } catch (...) {
      std::lock_guard<std::mutex> g(mutex); --workers; info->m_active = false; return false;
    }
  }
  bool startThread(ThreadInfo* info) override {
    if (!startWaitableThread(info)) return false;
    info->handle.detach(); return true;
  }
  bool waitStopped() {
    std::unique_lock<std::mutex> g(mutex);
    return changed.wait_for(g, std::chrono::seconds(12), [this] { return workers == 0; });
  }
  std::string getExecutablePath() override { return directory + "/peercast_mobile"; }
  std::vector<std::string> getAllIPAddresses() override {
    std::vector<std::string> result;
    ifaddrs* interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0) return result;
    for (auto i = interfaces; i; i = i->ifa_next) {
      if (!i->ifa_addr) continue;
      const int family = i->ifa_addr->sa_family;
      if (family != AF_INET && family != AF_INET6) continue;
      char address[NI_MAXHOST];
      if (getnameinfo(i->ifa_addr, family == AF_INET ? sizeof(sockaddr_in) : sizeof(sockaddr_in6), address, sizeof(address), nullptr, 0, NI_NUMERICHOST) == 0) result.emplace_back(address);
    }
    freeifaddrs(interfaces); return result;
  }
  void exit() override { running = false; }
  void executeFile(const char*) override {}
  void openURL(const char*) {}
  void callLocalURL(const char*, int) override {}
};
class MobileApp final : public PeercastApplication {
 public:
  const char* getClientTypeOS() override { return "Mobile"; }
  const char* getIniFilename() override { return nullptr; }
  const char* getPath() override { return directory.c_str(); }
  const char* getSettingsDirPath() override { return directory.c_str(); }
  const char* getStateDirPath() override { return directory.c_str(); }
  const char* getCacheDirPath() override { return directory.c_str(); }
  void printLog(LogBuffer::TYPE type, const char* message) override {
    // iOS has no Android logcat. Preserve a bounded connection-specific error
    // so a receiving timeout can be diagnosed on a physical device as well.
    if (type == LogBuffer::T_ERROR &&
        (std::strncmp(message, "Channel to ", 11) == 0 ||
         std::strncmp(message, "PCP readPacket:", 15) == 0 ||
         std::strcmp(message, "Channel giving up") == 0 ||
         std::strcmp(message, "Channel not found") == 0)) {
      const std::string text(message);
      std::lock_guard<std::mutex> g(connectionErrorMutex);
      if (!connectionError.empty()) connectionError += " / ";
      connectionError += text.substr(0, 240);
      while (connectionError.size() > 768) {
        const auto boundary = connectionError.find(" / ");
        connectionError.erase(0, boundary == std::string::npos ? connectionError.size() : boundary + 3);
      }
    }
#ifdef __ANDROID__
    __android_log_print(type == LogBuffer::T_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_INFO, "PeerCastCore", "%s", message);
#endif
  }
};
class MobileInstance final : public PeercastInstance {
 public:
  Sys* createSys() override { return new MobileSys(); }
};
MobileApp app;
MobileInstance instance;
std::shared_ptr<Channel> selected;
void interruptSocket(const std::shared_ptr<ClientSocket>& socket) {
  if (socket) ::shutdown(socket->getDescriptor(), SHUT_RDWR);
}
int fail(const std::string& message) { lastError = message; return -1; }
}
// No management endpoints, arbitrary files, POST, broadcasting or other channels.
bool mobileRequestAllowed(const char* line, bool local) {
  std::lock_guard<std::mutex> g(requestMutex);
  if (!running) return false;
  const std::string request(line);
  if (request.rfind("pcp", 0) == 0 || request.rfind("GIV", 0) == 0) return true;
  if (activeId.empty()) return false;
  const auto end = request.find(' ', 4);
  if (end == std::string::npos || request.rfind("GET ", 0) != 0) return false;
  const auto path = request.substr(4, end - 4);
  const bool localPlayback = local &&
      (path == "/stream/" + activeId || path == "/stream/" + activeId + ".flv");
  // The player reads localhost HTTP after the core starts receiving.
  // Only virtual-device playback may proceed without an external port check.
  if (localPlayback) return portState == 1 || isEmulator();
  return portState == 1 && relaysAllowed && path == "/channel/" + activeId;
}
EXPORT const char* pc_error() { return lastError.c_str(); }
EXPORT int pc_stop() {
  std::lock_guard<std::recursive_mutex> api(apiMutex);
  if (!sys) return 0;
  running = false;
  { std::lock_guard<std::mutex> g(probeMutex); interruptSocket(probeSocket); }
  { std::lock_guard<std::mutex> g(requestMutex); activeId.clear(); }
  instance.isQuitting = true;
  servMgr->serverThread.shutdown(); servMgr->idleThread.shutdown();
  // Prevent the listener creating a new connection while shutdown is collected.
  std::vector<std::shared_ptr<Channel>> channels;
  {
    std::lock_guard<std::recursive_mutex> g(chanMgr->lock);
    for (auto c = chanMgr->channel; c; c = c->next) channels.push_back(c);
  }
  for (const auto& c : channels) {
    c->thread.shutdown();
    std::lock_guard<std::recursive_mutex> g(c->lock);
    interruptSocket(c->sock); interruptSocket(c->pushSock);
  }
  {
    std::lock_guard<std::recursive_mutex> g(servMgr->lock);
    servMgr->autoServe = false; servMgr->autoConnect = false;
    for (auto s = servMgr->servents; s; s = s->next) {
      s->thread.shutdown();
      std::lock_guard<std::recursive_mutex> sg(s->lock);
      interruptSocket(s->sock);
    }
  }
  if (!static_cast<MobileSys*>(sys)->waitStopped()) return fail("Core threads did not stop in time; restart the app");
  for (auto& c : channels) if (c->thread.handle.joinable()) c->thread.handle.join();
  selected.reset();
  // Servents are reused only after all detached workers have returned.
  for (auto s = servMgr->servents; s; s = s->next) s->abort();
  chanMgr->clearHitLists();
  return 0;
}
EXPORT int pc_start(const char* path, int port, int relays) {
  std::lock_guard<std::recursive_mutex> api(apiMutex);
  try {
    if (port < 1024 || port > 65535 || relays < 1 || relays > 16) return fail("Invalid port or relay limit");
    if (sys && pc_stop() != 0) return -1;
    directory = path;
    if (!sys) {
      peercastApp = &app; peercastInst = &instance;
      sys = instance.createSys(); servMgr = new ServMgr(); chanMgr = new ChanMgr(); g_ypList = new YPList();
    }
    { std::lock_guard<std::mutex> g(connectionErrorMutex); connectionError.clear(); }
    instance.isQuitting = false;
    servMgr->allowServer1 = Servent::ALLOW_NETWORK;
    servMgr->maxRelays = relays; chanMgr->maxRelaysPerChannel = relays;
    servMgr->maxDirect = 1; servMgr->maxServIn = 12;
    servMgr->serverHost.port = port; servMgr->serverHostIPv6.port = port;
    servMgr->forceNormal = false; servMgr->firewalled = ServMgr::FW_UNKNOWN;
    servMgr->autoServe = true; servMgr->autoConnect = false;
    servMgr->rootHost.clear(); servMgr->restartServer = false;
    stats.clear();
    mobileExternalTraffic.clear();
    portState = 0; checkingPort = false;
    { std::lock_guard<std::mutex> g(probeMutex); portCheckError.clear(); }
    relaysAllowed = true; running = true;
    if (!servMgr->start()) { pc_stop(); return fail("Cannot start core threads"); }
    lastError.clear(); return 0;
  } catch (const std::exception& e) { pc_stop(); return fail(e.what()); }
    catch (...) { pc_stop(); return fail("Native initialization failed"); }
}
// Probe without starting a channel. Keep the socket interruptible by pc_stop.
EXPORT int pc_check_port(const char* tracker, const char* channelId) {
  std::lock_guard<std::recursive_mutex> api(apiMutex);
  if (!running) return fail("Inactive engine");
  if (!channelId || !std::regex_match(channelId, std::regex("[A-Fa-f0-9]{32}")))
    return fail("Invalid port check channel");
  if (checkingPort) return 0;
  probeChannelId = channelId;
  probeTracker = tracker;
  portCheckStarted = std::chrono::steady_clock::now();
  checkingPort = true;
  probeThread.func = [](ThreadInfo*) -> int {
    int result = 2;
    std::string detail = "確認先との通信に失敗しました";
    try {
      // pc_start launches the listener asynchronously. Do not ask the peer
      // to call back until bind/listen has completed.
      bool listening = false;
      for (int i = 0; i < 100 && running; ++i) {
        {
          std::lock_guard<std::recursive_mutex> g(servMgr->lock);
          for (auto s = servMgr->servents; s; s = s->next) {
            std::lock_guard<std::recursive_mutex> sg(s->lock);
            if (s->type == Servent::T_SERVER && s->status == Servent::S_LISTENING) listening = true;
          }
        }
        if (listening) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
      }
      detail = "待受ポートを開始できませんでした";
      if (!listening || !running) throw GeneralException("Listener not ready");
      detail = "確認先との接続または応答の取得に失敗しました";
      auto host = Host::fromString(probeTracker.c_str(), 7144);
      if (!host.ip.isIPv4Mapped()) {
        detail = "確認先のIPv4アドレスを取得できませんでした";
        throw GeneralException("IPv4 reachability required");
      }
      auto socket = sys->createSocket();
      socket->setReadTimeout(20000);
      socket->setWriteTimeout(10000);
      socket->open(host);
      {
        std::lock_guard<std::mutex> g(probeMutex);
        if (!running) { checkingPort = false; return 0; }
        probeSocket = socket;
      }
      socket->connect();
      AtomStream atom(*socket);
      // A bare PCP_CONNECT reaches PeerCastStation's pong-only handler,
      // which returns just a session ID and does not perform a reverse probe.
      // Use the relay handshake (200 or full/busy 503) on both YT and Station.
      socket->writeLineF("GET /channel/%s HTTP/1.0", probeChannelId.c_str());
      socket->writeLine("x-peercast-pcp: 1");
      socket->writeLine("");
      char line[4096];
      auto readLine = [&] {
        if (socket->readLine(line, sizeof(line)) >= static_cast<int>(sizeof(line) - 1))
          throw GeneralException("Port check HTTP header too long");
      };
      readLine();
      if (!std::regex_match(line, std::regex("HTTP/1\\.[01] (200|503)( .*)?"))) {
        detail = "確認先がポート確認に対応していないか、配信が終了しています";
        throw GeneralException("Unexpected port check HTTP status");
      }
      const bool busyTracker = std::string(line).find(" 503") != std::string::npos;
      bool headersComplete = false;
      for (int i = 0; i < 64; ++i) {
        readLine();
        if (!line[0]) { headersComplete = true; break; }
      }
      if (!headersComplete) throw GeneralException("Too many port check HTTP headers");
      // Always request a fresh reverse connection to the configured port.
      Servent::writeHeloAtom(atom, false, true, false, servMgr->sessionID,
                            servMgr->serverHost.port, chanMgr->broadcastID);
      int children, bytes;
      if (atom.read(children, bytes) != PCP_OLEH || children < 0 || children > 64)
        throw GeneralException("Invalid port check response");
      Host external;
      bool sessionValid = false, portReceived = false;
      for (int i = 0; i < children; ++i) {
        int count, length;
        auto id = atom.read(count, length);
        if (id == PCP_HELO_PORT && count == 0 && length == 2) {
          external.port = atom.readShort(); portReceived = true;
        }
        else if (id == PCP_HELO_REMOTEIP) external.ip = atom.readAddress();
        else if (id == PCP_HELO_SESSIONID && length == 16) {
          GnuID remote; atom.readBytes(remote.id, 16);
          sessionValid = remote.isSet() && !remote.isSame(servMgr->sessionID);
        } else atom.skip(count, length);
      }
      if (sessionValid && external.globalIP() && external.port == servMgr->serverHost.port) {
        // Publish the verified address/port to the core as well as the UI.
        // The next outgoing PCP HELO uses getFirewall(), not portState.
        // Leaving it UNKNOWN asks for another reverse probe without advertising
        // our verified port, which can stall/reject the actual relay handshake.
        {
          std::lock_guard<std::recursive_mutex> g(servMgr->lock);
          servMgr->updateIPAddress(external.ip);
          servMgr->setFirewall(4, ServMgr::FW_OFF);
        }
        result = 1;
        detail.clear();
      } else {
        detail = portReceived && external.port == 0
          ? "確認先から逆接続できないと応答されました。iPhoneへのポート転送を確認してください"
          : "確認先から有効なポート確認結果を取得できませんでした";
      }
      // A relay-style port probe also consumes the tracker's referral list.
      // YT throttles each advertised hit for 2 seconds; discarding these hosts
      // makes the immediately following fetch see 1003 with no alternatives.
      // Preserve only HOST suggestions after a verified 503 probe. Do not open
      // media, process broadcasts/pushes, or let optional data invalidate OLEH.
      if (result == 1 && busyTracker) {
        try {
          socket->setReadTimeout(1000);
          const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
          auto referrals = std::make_unique<PCPStream>(servMgr->sessionID);
          BroadcastState state; state.chanID.fromStr(probeChannelId.c_str());
          for (int i = 0; i < 16 && running && std::chrono::steady_clock::now() < deadline; ++i) {
            if (!socket->readReady(200)) break;
            int count, length;
            const auto id = atom.read(count, length);
            if (id != PCP_HOST || count < 0 || count > 64 || length != 0) break;
            // Bound nested atoms/payload size using the core's packet buffer.
            ChanPacket packet;
            MemoryStream buffer(packet.data, sizeof(packet.data));
            AtomStream encoded(buffer);
            encoded.writeAtoms(id, *socket, count, length);
            buffer.rewind();
            encoded.read(count, length);
            referrals->readHostAtoms(encoded, count, state);
          }
        } catch (...) { /* Referral delivery is best effort, not port proof. */ }
      }
      // OLEH is the result. A peer may close immediately afterwards (e.g.
      // an off-air or busy tracker). QUIT is best-effort cleanup and must
      // never turn a verified reverse connection into a failed port check.
      try { atom.writeInt(PCP_QUIT, PCP_ERROR_QUIT); } catch (...) {}
      try { socket->close(); } catch (...) {}
    } catch (...) { result = 2; }
    {
      std::lock_guard<std::mutex> g(probeMutex);
      probeSocket.reset();
      portCheckError = detail;
    }
    portState = result;
    checkingPort = false;
    return 0;
  };
  if (!sys->startThread(&probeThread)) {
    checkingPort = false; portState = 2;
    return fail("Cannot start port check");
  }
  return 0;
}
EXPORT int pc_connect(const char* id, const char* tracker) {
  std::lock_guard<std::recursive_mutex> api(apiMutex);
  try {
    if (!running || !std::regex_match(id, std::regex("[A-Fa-f0-9]{32}"))) return fail("Invalid channel or inactive engine");
    if (portState != 1 && !isEmulator()) return fail("Port reachability has not been verified");
    if (selected) return fail("Stop the current session before selecting another channel");
    auto host = Host::fromString(tracker, 7144);
    if (host.port == 0) return fail("Invalid tracker port");
    ChanInfo info; info.id.fromStr(id); info.contentType = ChanInfo::T_FLV;
    chanMgr->addHit(host, info.id, true);
    { std::lock_guard<std::mutex> g(requestMutex); activeId = info.id.str(); }
    selected = chanMgr->createRelay(info, true);
    if (!selected) return fail("Cannot create relay channel");
    return 0;
  } catch (const std::exception& e) { return fail(e.what()); }
    catch (...) { return fail("Native connection failed"); }
}
EXPORT int pc_set_relays(int count) {
  std::lock_guard<std::recursive_mutex> api(apiMutex);
  if (!running || count < 1 || count > 16) return fail("Invalid relay configuration");
  std::lock_guard<std::recursive_mutex> g(servMgr->lock);
  relaysAllowed = count > 0; servMgr->maxRelays = count; chanMgr->maxRelaysPerChannel = count;
  if (count == 0) for (auto s = servMgr->servents; s; s = s->next) if (s->type == Servent::T_RELAY) { s->thread.shutdown(); interruptSocket(s->sock); }
  return 0;
}
EXPORT const char* pc_snapshot() {
  std::lock_guard<std::recursive_mutex> api(apiMutex);
  static std::string output;
  try {
    nlohmann::json j = {{"running", running.load()}, {"playing", false}, {"relays", 0}, {"bytesOut", 0}, {"firewall", "unknown"}, {"status", "stopped"}};
    if (running && servMgr) {
      {
      std::lock_guard<std::recursive_mutex> g(servMgr->lock);
      j["listening"] = false;
      for (auto s = servMgr->servents; s; s = s->next) {
        std::lock_guard<std::recursive_mutex> sg(s->lock);
        if (s->type == Servent::T_SERVER && s->status == Servent::S_LISTENING) j["listening"] = true;
      }
      j["relays"] = servMgr->numStreams(Servent::T_RELAY, true);
      j["bytesOut"] = mobileExternalTraffic.sent();
      j["outboundMbps"] = mobileExternalTraffic.mbps();
      {
        std::lock_guard<std::mutex> pg(probeMutex);
        if (checkingPort && std::chrono::steady_clock::now() - portCheckStarted > std::chrono::seconds(30)) {
          portState = 2;
          portCheckError = "ポート確認がタイムアウトしました";
        }
        j["portCheckError"] = portCheckError;
      }
      j["firewall"] = portState == 1 ? "reachable" : portState == 2 ? "blocked" : "unknown";
      }
      if (selected) { std::lock_guard<std::recursive_mutex> cg(selected->lock); j["playing"] = selected->isPlaying(); j["status"] = Channel::statusMsgs[selected->status]; }
    }
    { std::lock_guard<std::mutex> g(connectionErrorMutex); j["connectionError"] = connectionError; }
    output = j.dump();
  } catch (...) { output = "{\"running\":false,\"status\":\"snapshot error\"}"; }
  return output.c_str();
}



