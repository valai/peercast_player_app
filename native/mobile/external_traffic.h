#pragma once

#include <atomic>
#include <cstdint>
#include <chrono>

// Count successful external socket writes directly: subtracting independently
// updated 32-bit total/local counters can wrap or include local playback bytes.
class MobileExternalTraffic {
public:
    using Clock = std::chrono::steady_clock;
    void recordSent(int bytes, bool local) {
        if (!local && bytes > 0)
            bytesOut.fetch_add(static_cast<std::uint64_t>(bytes), std::memory_order_relaxed);
    }
    std::uint64_t sent() const { return bytesOut.load(std::memory_order_relaxed); }
    // Only reset after the previous core's threads have stopped.
    // Sampling and reset are serialized by the bridge API mutex. Writers only
    // touch the atomic counter. Use actual monotonic time, not polling frequency.
    double mbps(Clock::time_point now = Clock::now()) {
        const double seconds = std::chrono::duration<double>(now - sampledAt).count();
        if (seconds >= 1.0) {
            const auto current = sent();
            rate = static_cast<double>(current - sampledBytes) * 8.0 / seconds / 1000000.0;
            sampledBytes = current;
            sampledAt = now;
        }
        return rate;
    }
    void clear(Clock::time_point now = Clock::now()) {
        bytesOut.store(0, std::memory_order_relaxed);
        sampledBytes = 0;
        sampledAt = now;
        rate = 0;
    }
private:
    std::atomic<std::uint64_t> bytesOut{0};
    std::uint64_t sampledBytes = 0;
    Clock::time_point sampledAt = Clock::now();
    double rate = 0;
};

inline MobileExternalTraffic mobileExternalTraffic;
