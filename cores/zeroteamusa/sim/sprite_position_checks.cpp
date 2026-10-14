#include "Vsprite_position_checks.h"
#include <cstdio>

int main() {
    Vsprite_position_checks dut;
    unsigned checks=0;
    for(unsigned xbits=0;xbits<2048;++xbits)
        for(unsigned tile=0;tile<16;++tile)
            for(unsigned flip=0;flip<2;++flip)
                for(unsigned side=0;side<2;++side)
                    for(unsigned k=0;k<8;++k) {
                        dut.sp_x=xbits; dut.tile_x_pf=tile;
                        dut.sp_flipx=flip; dut.pf_side=side; dut.k=k;
                        dut.eval();
                        int x=(xbits&1024) ? int(xbits)-2048 : int(xbits);
                        unsigned col=side*8+k;
                        if(flip) col=15-col;
                        unsigned expected=unsigned(x+int(tile*16+col))&2047;
                        if(dut.dx!=expected) {
                            std::printf("Sprite coordinate FAIL x=%d tile=%u flip=%u side=%u k=%u\n",
                                        x,tile,flip,side,k);
                            return 1;
                        }
                        ++checks;
                    }
    std::printf("PASS sprite X coordinates: %u checks including signed wrap and both flips\n",checks);
}
