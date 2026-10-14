#include "Vsprite_address_checks.h"
#include <cstdint>
#include <cstdio>

int main() {
    Vsprite_address_checks dut;
    uint32_t checks = 0;
    for(unsigned raster=0;raster<512;++raster) for(unsigned flip=0;flip<2;++flip) {
        dut.raster_y=raster;dut.flipped=flip;dut.eval();
        const unsigned expected=(flip ? (raster==255 ? 255 : 254-raster)
                                      : (raster==255 ? 0 : raster+1))&511;
        if(dut.target_y!=expected) {std::printf("Raster target FAIL\n");return 1;}
    }
    std::printf("PASS sprite raster target: 1024 checks, all rows and flip modes\n");
    for (unsigned x=0;x<16;++x) for(unsigned h=0;h<16;++h)
    for(unsigned y=0;y<16;++y) for(unsigned code=0;code<65536;++code) {
        dut.code_value=code;dut.tile_x=x;dut.tile_height=h;dut.tile_y=y;
        dut.eff_row=code&15;dut.pf_side=(code>>4)&1;
        dut.eval();
        const uint32_t tile=(code+x*h+y)&65535;
        const uint32_t address=(tile<<7)+((code&15)<<3)+(((code>>4)&1)<<2);
        if(dut.cur_tile!=tile || dut.address!=address) {
            std::printf("FAIL code=%u x=%u h=%u y=%u\n",code,x,h,y);
            return 1;
        }
        ++checks;
    }
    std::printf("PASS sprite tile/address arithmetic: %u checks; all codes "
                "and all 4-bit tile geometry values\n",checks);
}
