#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <poll.h>
#include <chrono>
#include <atomic>
#include <thread>
#include <string>
#include <stdexcept>
#include <cstdio>
#include <cstring>
#include <vector>
extern "C" int pc_start(const char*,int,int);
extern "C" int pc_check_port(const char*,const char*);
extern "C" int pc_stop();
extern "C" int pc_connect(const char*,const char*);
extern "C" const char* pc_snapshot();
extern "C" const char* pc_error();
static void require(bool b, const char* message) { if (!b) throw std::runtime_error(message); }
static void sendAll(int fd, const std::string& data) {
#ifdef MSG_NOSIGNAL
 constexpr int flags=MSG_NOSIGNAL;
#else
 constexpr int flags=0;
#endif
 size_t n=0; while(n<data.size()) { int r=send(fd,data.data()+n,data.size()-n,flags); require(r>0,"send"); n+=r; }
}
static std::string readBytes(int fd,int size) {
 std::string data(size,0); int n=0; while(n<size) { int r=recv(fd,&data[n],size-n,0); require(r>0,"receive"); n+=r; } return data;
}
static std::string number(unsigned int v,int size=4) { std::string s; while(size--) { s+=char(v&255); v>>=8; } return s; }
static unsigned int value(const std::string& s) { unsigned int v=0; for(int i=s.size()-1;i>=0;--i) v=(v<<8)|(unsigned char)s[i]; return v; }
static std::string atom(std::string id,std::string data) { id.resize(4,0); return id+number(data.size())+data; }
static std::string parent(std::string id,int n) { id.resize(4,0); return id+number(0x80000000|n); }
static std::string findAtom(int fd,const std::string& sought) {
 auto id=readBytes(fd,4); unsigned int length=value(readBytes(fd,4));
 if(length&0x80000000) { std::string result; for(unsigned int i=0;i<(length&0x7fffffff);++i) { auto s=findAtom(fd,sought); if(!s.empty()) result=s; } return result; }
 auto data=readBytes(fd,length); return id.substr(0,sought.size())==sought?data:"";
}
static int makeSocket() { int fd=socket(AF_INET,SOCK_STREAM,0);
#ifdef SO_NOSIGPIPE
 int noSigPipe=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSigPipe,sizeof(noSigPipe));
#endif
 timeval tv{5,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv)); return fd; }
static sockaddr_in address(int port) { sockaddr_in a{}; a.sin_family=AF_INET; a.sin_port=htons(port); a.sin_addr.s_addr=htonl(INADDR_LOOPBACK); return a; }
static std::string readLine(int fd) {
 std::string s; while(s.size()<4096) { auto c=readBytes(fd,1); s+=c; if(c=="\n") return s; }
 throw std::runtime_error("HTTP line too long");
}
int runScenario(const std::string& mode, const std::string& channel) {
 try {
  constexpr int port=17145, tracker=17999;
  int listener=makeSocket(); int reuse=1; setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
  auto a=address(tracker); require(bind(listener,(sockaddr*)&a,sizeof(a))==0,"bind"); require(listen(listener,1)==0,"listen");
  if(mode=="retry") { timeval timeout{30,0}; setsockopt(listener,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)); }
  int referralListener=-1;
  if(mode=="referrals") {
    referralListener=makeSocket(); setsockopt(referralListener,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
    auto destination=address(18000);
    require(bind(referralListener,(sockaddr*)&destination,sizeof(destination))==0,"bind referral");
    require(listen(referralListener,1)==0,"listen referral");
  }
  std::atomic<bool> relayDone{false};
  std::string peerError;
  std::thread peer([&] { int fd=-1; try {
    fd=accept(listener,nullptr,nullptr); require(fd>=0,"accept");
#ifdef SO_NOSIGPIPE
    int noSigPipe=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSigPipe,sizeof(noSigPipe));
#endif
    // Station's bare PCP endpoint only answers with a SID. A reverse check
    // must instead enter through the channel HTTP handshake, including 503.
    require(readLine(fd)=="GET /channel/"+channel+" HTTP/1.0\r\n","relay handshake required");
    require(readLine(fd)=="x-peercast-pcp: 1\r\n","PCP header required");
    require(readLine(fd)=="\r\n","HTTP header end");
    sendAll(fd,(mode == "busy" || mode == "referrals") ? "HTTP/1.0 503 Service Unavailable\r\n\r\n" : "HTTP/1.0 200 OK\r\n\r\n");
    // Read all HELO children and verify a fresh ping, not a claimed open port.
    require(readBytes(fd,4)=="helo","HELO required");
    auto count=value(readBytes(fd,4)); require((count&0x80000000)!=0,"HELO parent");
    std::string sid; unsigned int ping=0;
    for(unsigned int i=0;i<(count&0x7fffffff);++i) {
      auto id=readBytes(fd,4); auto data=readBytes(fd,value(readBytes(fd,4)));
      if(id==std::string("sid\0",4)) sid=data;
      if(id=="ping") ping=value(data);
      require(id!="port","must not claim an open port");
    }
    require(sid.size()==16,"request session"); require(ping==port,"reverse ping port");
    if(mode == "missing") {
      sendAll(fd,parent("oleh",1)+atom("sid",std::string(16,'x')));
      close(fd); return;
    }
    int reverse=makeSocket(); auto dest=address(port); require(connect(reverse,(sockaddr*)&dest,sizeof(dest))==0,"reverse connect");
    sendAll(reverse,atom("pcp\n",number(1))+parent("helo",1)+atom("sid",std::string(16,'x')));
    auto actual=findAtom(reverse,"sid"); require(actual==sid,"reverse session mismatch"); close(reverse);
    std::string referral;
    if(mode=="referrals") {
      std::string cid;
      for(size_t i=0;i<channel.size();i+=2) cid+=char(std::stoul(channel.substr(i,2),nullptr,16));
      referral=parent("host",7)+atom("cid",cid)+atom("id",std::string(16,'y'))+
        atom("ip",number(0x7f000001))+atom("port",number(18000,2))+
        atom("ip",number(0))+atom("port",number(0,2))+atom("flg1",number(0x12,1))+atom("quit",number(1003));
    }
    sendAll(fd,parent("oleh",3)+atom("sid",mode == "invalid" ? std::string(16,0) : std::string(16,'x'))+atom("rip",number(0x08080808))+atom("port",number(mode == "blocked" ? 0 : mode == "wrong_port" ? port+1 : port,2))+referral);
    if (mode == "reset") {
      // Wait until OLEH was consumed before resetting. An immediate RST may
      // discard unread OLEH bytes on macOS rather than test post-result close.
      findAtom(fd,"quit");
      linger reset{1,0}; setsockopt(fd,SOL_SOCKET,SO_LINGER,&reset,sizeof(reset)); }
    else findAtom(fd,"quit");
    close(fd);
    if (mode == "relay" || mode == "connect" || mode == "rejected" || mode == "retry" || mode == "referrals") {
      auto retryStart=std::chrono::steady_clock::now();
      for(int attempt=0;attempt<(mode=="retry"?2:1);++attempt) {
      if(mode=="referrals") {
        pollfd destinations[2]={{referralListener,POLLIN,0},{listener,POLLIN,0}};
        require(poll(destinations,2,5000)>0,"no connection to referral");
        const bool usedReferral=destinations[0].revents&POLLIN;
        fd=accept(usedReferral?referralListener:listener,nullptr,nullptr);
        require(usedReferral,"port-check referrals were discarded; fetched tracker again");
      } else {
      pollfd incoming{listener,POLLIN,0};
      require(poll(&incoming,1,25000)>0,"tracker was not retried within 25 seconds");
      fd=accept(listener,nullptr,nullptr); require(fd>=0,"accept playback");
      }
      if(attempt==1) require(std::chrono::steady_clock::now()-retryStart>=std::chrono::seconds(8),"busy tracker retried too aggressively");
      require(readLine(fd)=="GET /channel/"+channel+" HTTP/1.0\r\n","playback request");
      while(readLine(fd)!="\r\n") {}
      if(mode=="rejected") {
        sendAll(fd,"HTTP/1.0 404 Not Found\r\n\r\n");
        close(fd); return;
      }
      sendAll(fd,"HTTP/1.0 200 OK\r\nContent-Type: application/x-peercast-pcp\r\n\r\n");
      require(readBytes(fd,4)=="helo","playback HELO");
      auto count=value(readBytes(fd,4)); require((count&0x80000000)!=0,"playback HELO parent");
      unsigned int advertisedPort=0; bool repeatedPing=false;
      for(unsigned int i=0;i<(count&0x7fffffff);++i) {
        auto id=readBytes(fd,4); auto data=readBytes(fd,value(readBytes(fd,4)));
        if(id=="port") advertisedPort=value(data);
        if(id=="ping") repeatedPing=true;
      }
      // The successful independent probe must also update the relay core.
      // Otherwise every fetch asks for another reverse connection and can
      // advertise itself as firewalled despite having just passed the probe.
      require(advertisedPort==port,"verified port missing from playback HELO");
      require(!repeatedPing,"playback repeated an already successful reverse probe");
      sendAll(fd,parent("oleh",3)+atom("sid",std::string(16,'x'))+atom("rip",number(0x08080808))+atom("port",number(port,2)));
      if(mode=="retry" && attempt==0) {
        retryStart=std::chrono::steady_clock::now();
        sendAll(fd,atom("quit",number(1003))); close(fd); continue;
      }
      std::string channelId;
      for(size_t i=0;i<channel.size();i+=2) channelId+=char(std::stoul(channel.substr(i,2),nullptr,16));
      const std::string flv("FLV\x01\x01\x00\x00\x00\x09\x00\x00\x00\x00",13);
      sendAll(fd,parent("chan",2)+atom("id",channelId)+parent("pkt",3)+atom("type","head")+atom("pos",number(0))+atom("data",flv));
      if(mode=="relay") {
        for(int i=0;i<100 && !relayDone;++i) {
          sendAll(fd,parent("chan",2)+atom("id",channelId)+parent("pkt",3)+atom("type","data")+
            atom("pos",number(13+i*32))+atom("data",std::string(32,'R')));
          std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
      } else std::this_thread::sleep_for(std::chrono::milliseconds(500));
      close(fd);
      }
    }
  } catch(const std::exception& e) { peerError=e.what(); if(fd>=0) close(fd); } });
  require(pc_start("/data/local/tmp",port,1)==0,pc_error());
  require(pc_check_port("127.0.0.1:17999",channel.c_str())==0,pc_error());
  std::string state;
  for(int i=0;i<100;++i) { state=pc_snapshot(); if(state.find("reachable")!=std::string::npos || state.find("blocked")!=std::string::npos) break; std::this_thread::sleep_for(std::chrono::milliseconds(100)); }
  require(state.find("\"connectionError\":\"\"")!=std::string::npos,"previous connection error survived restart");
  bool received=false;
  if((mode=="relay" || mode=="connect" || mode=="rejected" || mode=="retry" || mode=="referrals") && state.find("reachable")!=std::string::npos) {
    require(pc_connect(channel.c_str(),"127.0.0.1:17999")==0,pc_error());
    for(int i=0;i<(mode=="retry"?300:50);++i) {
      state=pc_snapshot();
      if(mode=="rejected" && state.find("Channel not found")!=std::string::npos) break;
      if(state.find("\"playing\":true")!=std::string::npos) { received=true; break; }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }
  std::string relayError;
  if(mode=="relay" && received) {
    int downstream=-1;
    try {
      require(state.find("\"relays\":0")!=std::string::npos,"idle relay count is not zero");
      downstream=makeSocket(); auto target=address(port);
      require(connect(downstream,(sockaddr*)&target,sizeof(target))==0,"downstream connect");
      sendAll(downstream,"GET /channel/"+channel+" HTTP/1.0\r\nx-peercast-pcp: 1\r\n\r\n");
      require(readLine(downstream).find("200")!=std::string::npos,"downstream HTTP not accepted");
      while(readLine(downstream)!="\r\n") {}
      sendAll(downstream,parent("helo",3)+atom("sid",std::string(16,'z'))+
        atom("ver",number(1218))+atom("agnt",std::string("RelayTest\0",10)));
      require(findAtom(downstream,"sid").size()==16,"downstream OLEH missing");
      bool header=false,data=false;
      for(int i=0;i<10 && !data;++i) {
        auto payload=findAtom(downstream,"data");
        if(payload==std::string("FLV\x01\x01\x00\x00\x00\x09\x00\x00\x00\x00",13)) header=true;
        if(payload==std::string(32,'R')) data=true;
      }
      require(header && data,"relay did not forward header and stream payload");
      state=pc_snapshot();
      require(state.find("\"relays\":1")!=std::string::npos,"connected relay count did not become one");
      printf("relay connected: %s\n",state.c_str());
      sendAll(downstream,atom("quit",number(1000))); close(downstream); downstream=-1;
      for(int i=0;i<40;++i) {
        state=pc_snapshot();
        if(state.find("\"relays\":0")!=std::string::npos) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
      require(state.find("\"relays\":0")!=std::string::npos,"disconnected relay count did not return to zero");
    } catch(const std::exception& e) { relayError=e.what(); }
    if(downstream>=0) close(downstream);
  }
  relayDone=true;
  peer.join(); close(listener); if(referralListener>=0) close(referralListener); pc_stop();
  require(state.find("\"listening\":true")!=std::string::npos,"listener readiness missing");
  printf("state: %s; peer: %s\n",state.c_str(),peerError.c_str());
  require(relayError.empty(),relayError.c_str());
  require(peerError.empty(),"reverse PCP exchange failed");
  const bool shouldPass = mode == "normal" || mode == "reset" || mode == "busy" || mode == "relay" || mode == "connect" || mode == "rejected" || mode == "retry" || mode == "referrals";
  require(state.find(shouldPass ? "reachable" : "blocked")!=std::string::npos,"unexpected port result");
  if (mode == "missing") require(state.find("逆接続できない") == std::string::npos,"missing port is not a negative probe");
  if (!shouldPass) require(state.find("portCheckError")!=std::string::npos,"missing diagnostic");
  if(mode=="rejected") require(state.find("Channel not found")!=std::string::npos,"missing native rejection diagnostic");
  if(mode=="relay" || mode=="connect" || mode=="retry" || mode=="referrals") require(received,"verified session did not receive channel data");
  puts(mode=="relay" ? "PASS: relay forwards header/data and count changes 0 -> 1 -> 0" : "PASS: external probe with reverse PCP handshake"); return 0;
 } catch(const std::exception& e) { fprintf(stderr,"FAIL: %s\n",e.what()); return 1; }
}

int main(int argc, char** argv) {
 const std::string mode = argc > 1 ? argv[1] : "normal";
 const std::string a="0123456789ABCDEF0123456789ABCDEF";
 const std::string b="FEDCBA9876543210FEDCBA9876543210";
 if(mode=="switch") {
   if(runScenario("rejected",a)!=0) return 1;
   // Keep the actual native globals alive across A -> B -> A.
   for(const auto& channel : {a,b,a}) {
     if(runScenario("connect",channel)!=0) return 1;
   }
   puts("PASS: channel A -> B -> A in one process");
   return 0;
 }
 return runScenario(mode,a);
}
