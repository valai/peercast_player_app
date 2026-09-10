#pragma once

#include <cstddef>
#include <cstdint>

// Repair only flags proven by complete tags in the initialization packet.
// Call on a local playback copy; never modify the shared relay packet.
inline void mobileRepairFlvHeader(void* data, std::size_t size) {
    auto* bytes = static_cast<uint8_t*>(data);
    if (size < 13 || bytes[0] != 'F' || bytes[1] != 'L' ||
        bytes[2] != 'V' || bytes[3] != 1 || (bytes[4] & 0xfa) != 0) return;
    const auto read32 = [](const uint8_t* p) -> uint32_t {
        return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
               (uint32_t(p[2]) << 8) | p[3];
    };
    const std::size_t offset = read32(bytes + 5);
    if (offset < 9 || offset > size - 4 || read32(bytes + offset) != 0) return;
    std::size_t pos = offset + 4;
    while (size - pos >= 15) {
        const std::size_t length = (std::size_t(bytes[pos + 1]) << 16) |
                                  (std::size_t(bytes[pos + 2]) << 8) | bytes[pos + 3];
        if (length > size - pos - 15) break;
        if (bytes[pos + 8] || bytes[pos + 9] || bytes[pos + 10] ||
            read32(bytes + pos + 11 + length) != 11 + length) break;
        if (length > 0) {
            if (bytes[pos] == 8) bytes[4] |= 0x04;
            if (bytes[pos] == 9) bytes[4] |= 0x01;
        }
        pos += 15 + length;
    }
}
