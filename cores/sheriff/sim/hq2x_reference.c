// SPDX-License-Identifier: GPL-3.0-or-later
// Use the independent LGPL-2.1 hqx library; no RTL rules are transcribed here.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "hqx.h"

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    // Include the actual neighbours of the active viewport. MiSTer clears
    // its three left-neighbour pipeline pixels at each HBlank falling edge
    // (sys/hq2x.sv), so the independent reference gets a black left border.
    enum { W = 258, H = 226 };
    uint32_t *source = calloc(W * H, sizeof(uint32_t));
    uint32_t *target = calloc(W * H * 4, sizeof(uint32_t));
    if (!source || !target) return 2;
    for (unsigned y = 0; y < H; ++y) for (unsigned x = 0; x < W; ++x) {
        unsigned sx = x ? x - 1 : 0, sy = y + 15;
        unsigned colour = ((sx / 8) + (sy / 8)) & 7;
        source[y * W + x] = x == 0 ? 0 : ((colour & 1) ? 0xff0000 : 0)
                           | ((colour & 2) ? 0x00ff00 : 0)
                           | ((colour & 4) ? 0x0000ff : 0);
    }
    hqxInit();
    hq2x_32(source, target, W, H);
    FILE *out = fopen(argv[1], "wb");
    if (!out) return 2;
    for (unsigned y = 0; y < 448; ++y) for (unsigned x = 0; x < 512; ++x) {
        uint32_t p = target[(y + 2) * (W * 2) + x + 2];
        unsigned char rgb[3] = {p >> 16, p >> 8, p};
        if (fwrite(rgb, 1, 3, out) != 3) return 2;
    }
    fclose(out); free(source); free(target);
    return 0;
}
