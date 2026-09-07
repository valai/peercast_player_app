#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <thread>
#include <chrono>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
extern "C" int pc_start(const char*,int,int);
extern "C" int pc_connect(const char*,const char*);
extern "C" int pc_stop();
extern "C" int pc_set_relays(int);
extern "C" const char* pc_snapshot();
extern "C" const char* pc_error();
int main(int argc, char** argv) {
  const char* id = argc > 1 ? argv[1] : "0123456789ABCDEF0123456789ABCDEF";
  const char* tracker = argc > 2 ? argv[2] : "127.0.0.1:17999";
  const int port = argc > 3 ? std::atoi(argv[3]) : 17144;
  const int duration = argc > 4 ? std::atoi(argv[4]) : 15;
  bool received = false;
  for (int cycle=0; cycle<(argc > 1 ? 1 : 2); ++cycle) {
    if (pc_start("/data/local/tmp", port, 1) != 0) { puts(pc_error()); return 1; }
    if (pc_connect(id, tracker) != 0) { puts(pc_error()); return 2; }
    std::this_thread::sleep_for(std::chrono::seconds(2));
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    timeval tv{3,0}; setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
    sockaddr_in addr{}; addr.sin_family=AF_INET; addr.sin_port=htons(port); inet_pton(AF_INET,"127.0.0.1",&addr.sin_addr);
    if (connect(fd,(sockaddr*)&addr,sizeof(addr)) != 0) { puts("listener unavailable"); pc_stop(); return 3; }
    const char* request="GET /admin?cmd=shutdown HTTP/1.0\r\n\r\n";
    send(fd,request,strlen(request),0); char response[256]{}; recv(fd,response,255,0); close(fd);
    printf("admin response: %s\n",response);
    if (strstr(response,"403") == nullptr) { pc_stop(); return 4; }
    if (argc > 1) for(int i=0;i<duration;++i) {
      const std::string state = pc_snapshot(); puts(state.c_str());
      if (!received && state.find("\"playing\":true") != std::string::npos) {
        int stream=socket(AF_INET,SOCK_STREAM,0); setsockopt(stream,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
        if(connect(stream,(sockaddr*)&addr,sizeof(addr))==0) {
          auto get=std::string("GET /stream/")+id+".flv HTTP/1.0\r\n\r\n";
          send(stream,get.data(),get.size(),0);
          std::string body; char buffer[4096];
          while(body.size()<65536) { int n=recv(stream,buffer,sizeof(buffer),0); if(n<=0) break; body.append(buffer,n); if(body.find("FLV")!=std::string::npos) { received=true; puts("PASS: FLV header received through local stream endpoint"); break; } }
        }
        close(stream);
      }
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    puts(pc_snapshot());
    if(pc_set_relays(0)!=0) return 5;
    int denied=socket(AF_INET,SOCK_STREAM,0); setsockopt(denied,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
    if(connect(denied,(sockaddr*)&addr,sizeof(addr))!=0) return 9;
    auto relayRequest=std::string("GET /channel/")+id+" HTTP/1.0\r\n\r\n";
    send(denied,relayRequest.data(),relayRequest.size(),0);
    char denial[256]{}; recv(denied,denial,255,0); close(denied);
    if(strstr(denial,"403")==nullptr) { puts("FAIL: relay accepted while disabled"); pc_stop(); return 10; }
    puts("PASS: disabled relay rejects new connections");
    if(pc_stop()!=0) { puts(pc_error()); return 6; }
    puts(pc_snapshot());
    int probe=socket(AF_INET,SOCK_STREAM,0);
    int connected=connect(probe,(sockaddr*)&addr,sizeof(addr)); close(probe);
    if(connected==0) { puts("listener leaked after stop"); return 7; }
  }
  if (argc > 1 && !received) { puts("FAIL: no FLV reception"); return 8; }
  puts("PASS: restart, management rejection, relay stop, listener shutdown"); return 0;
}

