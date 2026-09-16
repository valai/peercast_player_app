#include "external_traffic.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <thread>
#include <vector>

int main() {
    MobileExternalTraffic traffic;
    traffic.recordSent(1024, true);
    traffic.recordSent(0, false);
    traffic.recordSent(-1, false);
    assert(traffic.sent() == 0);
    // Exceed both signed and unsigned 32-bit limits.
    for (int i = 0; i < 5000; ++i) traffic.recordSent(1048576, false);
    assert(traffic.sent() == 5242880000ULL);
    traffic.clear();
    assert(traffic.sent() == 0);
    std::vector<std::thread> writers;
    for (int i = 0; i < 4; ++i) writers.emplace_back([&] {
        for (int n = 0; n < 10000; ++n) {
            traffic.recordSent(100, false);
            traffic.recordSent(200, true);
        }
    });
    std::uint64_t previous = 0;
    for (int i = 0; i < 10000; ++i) {
        const auto current = traffic.sent();
        assert(current >= previous && current <= 4000000);
        previous = current;
    }
    for (auto& writer : writers) writer.join();
    assert(traffic.sent() == 4000000);
    const auto start = MobileExternalTraffic::Clock::now();
    traffic.clear(start);
    assert(traffic.mbps(start) == 0);
    traffic.recordSent(125000, false);
    traffic.recordSent(999999, true);
    assert(traffic.mbps(start + std::chrono::milliseconds(400)) == 0);
    assert(traffic.mbps(start + std::chrono::seconds(1)) == 1.0);
    traffic.recordSent(312500, false);
    assert(traffic.mbps(start + std::chrono::milliseconds(3500)) == 1.0);
    assert(traffic.mbps(start + std::chrono::milliseconds(4500)) == 0);
    traffic.clear(start);
    assert(traffic.mbps(start + std::chrono::seconds(1)) == 0);
}
