#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <chrono>
#include <thread>
#include <string>
#include <stdexcept>
#include <cstdio>
#include <cstring>
#include <vector>
extern "C" int pc_start(const char*,int,int);
extern "C" int pc_check_port(const char*,const char*);
extern "C" int pc_stop();
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
int main(int argc, char** argv) {
 const std::string mode = argc > 1 ? argv[1] : "normal";
 try {
  constexpr int port=17145, tracker=17999;
  int listener=makeSocket(); int reuse=1; setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
  auto a=address(tracker); require(bind(listener,(sockaddr*)&a,sizeof(a))==0,"bind"); require(listen(listener,1)==0,"listen");
  std::string peerError;
  std::thread peer([&] { try {
    int fd=accept(listener,nullptr,nullptr); require(fd>=0,"accept");
#ifdef SO_NOSIGPIPE
    int noSigPipe=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSigPipe,sizeof(noSigPipe));
#endif
    // Station's bare PCP endpoint only answers with a SID. A reverse check
    // must instead enter through the channel HTTP handshake, including 503.
    require(readLine(fd)=="GET /channel/0123456789ABCDEF0123456789ABCDEF HTTP/1.0\r\n","relay handshake required");
    require(readLine(fd)=="x-peercast-pcp: 1\r\n","PCP header required");
    require(readLine(fd)=="\r\n","HTTP header end");
    sendAll(fd,mode == "busy" ? "HTTP/1.0 503 Service Unavailable\r\n\r\n" : "HTTP/1.0 200 OK\r\n\r\n");
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
    sendAll(fd,parent("oleh",3)+atom("sid",mode == "invalid" ? std::string(16,0) : std::string(16,'x'))+atom("rip",number(0x08080808))+atom("port",number(mode == "blocked" ? 0 : mode == "wrong_port" ? port+1 : port,2)));
    if (mode == "reset") {
      // Wait until OLEH was consumed before resetting. An immediate RST may
      // discard unread OLEH bytes on macOS rather than test post-result close.
      findAtom(fd,"quit");
      linger reset{1,0}; setsockopt(fd,SOL_SOCKET,SO_LINGER,&reset,sizeof(reset)); }
    else findAtom(fd,"quit");
    close(fd);
  } catch(const std::exception& e) { peerError=e.what(); } });
  require(pc_start("/data/local/tmp",port,1)==0,pc_error());
  require(pc_check_port("127.0.0.1:17999","0123456789ABCDEF0123456789ABCDEF")==0,pc_error());
  std::string state;
  for(int i=0;i<100;++i) { state=pc_snapshot(); if(state.find("reachable")!=std::string::npos || state.find("blocked")!=std::string::npos) break; std::this_thread::sleep_for(std::chrono::milliseconds(100)); }
  peer.join(); close(listener); pc_stop();
  require(state.find("\"listening\":true")!=std::string::npos,"listener readiness missing");
  printf("state: %s; peer: %s\n",state.c_str(),peerError.c_str());
  require(peerError.empty(),"reverse PCP exchange failed");
  const bool shouldPass = mode == "normal" || mode == "reset" || mode == "busy";
  require(state.find(shouldPass ? "reachable" : "blocked")!=std::string::npos,"unexpected port result");
  if (mode == "missing") require(state.find("逆接続できない") == std::string::npos,"missing port is not a negative probe");
  if (!shouldPass) require(state.find("portCheckError")!=std::string::npos,"missing diagnostic");
  puts("PASS: external probe with reverse PCP handshake"); return 0;
 } catch(const std::exception& e) { fprintf(stderr,"FAIL: %s\n",e.what()); return 1; }
}
