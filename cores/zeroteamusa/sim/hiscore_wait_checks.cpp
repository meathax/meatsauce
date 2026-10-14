#include "Vhiscore_wait_checks.h"
#include <cstdint>
#include <cstdio>

int main() {
    Vhiscore_wait_checks dut;
    uint32_t random = 0x6ab412f3;
    unsigned checks = 0;
    for (uint32_t hold = 0; hold < 65536; ++hold) {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        const uint32_t values[] = {
            0, 1, hold - 2, hold - 1, hold, hold + 1, hold + 2,
            65536, 0xffffffff, 0x80000000, random
        };
        for (const uint32_t timer : values) {
            dut.hold_cycles = hold;
            dut.previous_hold = hold - 1;
            dut.timer = timer;
            dut.eval();
            const uint32_t elapsed = hold - timer;
            if (dut.ready_one != (elapsed >= 1) ||
                dut.ready_two != (elapsed >= 2)) {
                std::printf("FAIL hold=%u timer=%u\n", hold, timer);
                return 1;
            }
            checks += 2;
        }
    }
    std::printf("PASS hiscore wait comparison: %u checks; both pipeline modes, "
                "all hold values, unsigned wrap and timer boundaries\n", checks);
}
