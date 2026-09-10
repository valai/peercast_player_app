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
extern "C" int pc_check_port(const char*);
extern "C" int pc_stop();
extern "C" const char* pc_snapshot();
extern "C" const char* pc_error();
static void require(bool b, const char* message) { if (!b) throw std::runtime_error(message); }
static void sendAll(int fd, const std::string& data) {
 size_t n=0; while(n<data.size()) { int r=send(fd,data.data()+n,data.size()-n,MSG_NOSIGNAL); require(r>0,"send"); n+=r; }
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
static int makeSocket() { int fd=socket(AF_INET,SOCK_STREAM,0); timeval tv{5,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv)); return fd; }
static sockaddr_in address(int port) { sockaddr_in a{}; a.sin_family=AF_INET; a.sin_port=htons(port); a.sin_addr.s_addr=htonl(INADDR_LOOPBACK); return a; }
int main(int argc, char** argv) {
 const std::string mode = argc > 1 ? argv[1] : "normal";
 try {
  constexpr int port=17145, tracker=17999;
  int listener=makeSocket(); int reuse=1; setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
  auto a=address(tracker); require(bind(listener,(sockaddr*)&a,sizeof(a))==0,"bind"); require(listen(listener,1)==0,"listen");
  std::string peerError;
  std::thread peer([&] { try {
    int fd=accept(listener,nullptr,nullptr); require(fd>=0,"accept");
    readBytes(fd,12); auto sid=findAtom(fd,"sid"); require(sid.size()==16,"request session");
    int reverse=makeSocket(); auto dest=address(port); require(connect(reverse,(sockaddr*)&dest,sizeof(dest))==0,"reverse connect");
    sendAll(reverse,atom("pcp\n",number(1))+parent("helo",1)+atom("sid",std::string(16,'x')));
    auto actual=findAtom(reverse,"sid"); require(actual==sid,"reverse session mismatch"); close(reverse);
    sendAll(fd,parent("oleh",3)+atom("sid",mode == "invalid" ? std::string(16,0) : std::string(16,'x'))+atom("rip",number(0x08080808))+atom("port",number(mode == "blocked" ? 0 : port,2)));
    if (mode == "reset") { linger reset{1,0}; setsockopt(fd,SOL_SOCKET,SO_LINGER,&reset,sizeof(reset)); }
    else findAtom(fd,"quit");
    close(fd);
  } catch(const std::exception& e) { peerError=e.what(); } });
  require(pc_start("/data/local/tmp",port,1)==0,pc_error());
  require(pc_check_port("127.0.0.1:17999")==0,pc_error());
  std::string state;
  for(int i=0;i<100;++i) { state=pc_snapshot(); if(state.find("reachable")!=std::string::npos || state.find("blocked")!=std::string::npos) break; std::this_thread::sleep_for(std::chrono::milliseconds(100)); }
  peer.join(); close(listener); pc_stop();
  require(state.find("\"listening\":true")!=std::string::npos,"listener readiness missing");
  printf("state: %s; peer: %s\n",state.c_str(),peerError.c_str());
  require(peerError.empty(),"reverse PCP exchange failed");
  const bool shouldPass = mode == "normal" || mode == "reset";
  require(state.find(shouldPass ? "reachable" : "blocked")!=std::string::npos,"unexpected port result");
  if (!shouldPass) require(state.find("portCheckError")!=std::string::npos,"missing diagnostic");
  puts("PASS: external probe with reverse PCP handshake"); return 0;
 } catch(const std::exception& e) { fprintf(stderr,"FAIL: %s\n",e.what()); return 1; }
}
