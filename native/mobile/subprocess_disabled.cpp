// Mobile intentionally has no CGI, shell, transcoder or external RTMP process.
#include "subprog.h"
bool Subprogram::start(const std::vector<std::string>&, Environment&) { return false; }
bool Subprogram::wait(int*) { return false; }
bool Subprogram::isAlive() { return false; }
void Subprogram::terminate() {}
Subprogram::Subprogram(const std::string& name, bool receive, bool feed)
  : m_receiveData(receive), m_feedData(feed), m_name(name),
    m_inputStream(std::make_shared<FileStream>()), m_outputStream(std::make_shared<FileStream>()), m_pid(-1) {}
Subprogram::~Subprogram() = default;
