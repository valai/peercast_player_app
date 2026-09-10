#include "flv_playback_header.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <fstream>
#include <iterator>
#include <vector>
#include <cstdio>

using Bytes = std::vector<uint8_t>;
Bytes header(uint8_t flags) { return {'F','L','V',1,flags,0,0,0,9,0,0,0,0}; }
void tag(Bytes& b, uint8_t type) {
    const Bytes t = {type,0,0,2,0,0,0,0,0,0,0,0xaf,0,0,0,0,13};
    b.insert(b.end(), t.begin(), t.end());
}
void repair(Bytes& b) { mobileRepairFlvHeader(b.data(), b.size()); }
int main(int argc, char** argv) {
    auto missing = header(1); tag(missing,18); tag(missing,9); tag(missing,8);
    const auto original = missing;
    repair(missing);
    auto expected = original; expected[4] = 5;
    assert(missing == expected); // Only the flags byte changes.
    repair(missing); assert(missing == expected);
    auto normal = header(5); tag(normal,8); tag(normal,9);
    const auto normalCopy = normal; repair(normal); assert(normal == normalCopy);
    auto videoOnly = header(1); tag(videoOnly,9);
    const auto videoCopy = videoOnly; repair(videoOnly); assert(videoOnly == videoCopy);
    auto audioOnly = header(0); tag(audioOnly,8); repair(audioOnly); assert(audioOnly[4] == 4);
    auto truncated = header(1); tag(truncated,8);
    for (std::size_t n=0; n<truncated.size(); ++n) {
        Bytes part(truncated.begin(), truncated.begin()+n);
        const auto copy = part; repair(part); assert(part == copy);
    }
    auto malformed = truncated; malformed.back() = 0;
    auto copy = malformed; repair(malformed); assert(malformed == copy);
    malformed = truncated; malformed[5] = 0xff;
    copy = malformed; repair(malformed); assert(malformed == copy);
    malformed = truncated; malformed[0] = 'X';
    copy = malformed; repair(malformed); assert(malformed == copy);
    // Extended FLV headers must use their declared data offset.
    auto extended = header(1); extended.insert(extended.begin()+9,4,0); extended[8]=13;
    tag(extended,8); repair(extended); assert(extended[4] == 5);
    if (argc > 1) {
        std::ifstream input(argv[1], std::ios::binary);
        Bytes captured((std::istreambuf_iterator<char>(input)), {});
        assert(captured.size() > 13 && captured[4] == 1);
        // The real initialization tags must be found within one head packet.
        auto prefix = Bytes(captured.begin(), captured.begin() +
                            (captured.size() < 16384 ? captured.size() : 16384));
        repair(prefix); assert(prefix[4] == 5);
        auto fixed = captured; repair(fixed); captured[4] = 5;
        assert(fixed == captured);
        puts("PASS: captured FLV changes only the audio flag");
    }
    puts("PASS: FLV playback header regression tests");
}
