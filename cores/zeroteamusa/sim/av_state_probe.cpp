// Read a native actual-RTL snapshot without clocking or altering the simulation.
#include "Vzero_av_top.h"
#include "Vzero_av_top___024root.h"
#include "verilated.h"
#include "verilated_save.h"
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
int main(int argc,char** argv) {
    if(argc!=3 && !(argc==4 && std::string(argv[3])=="--roundtrip"))
        throw std::runtime_error("Expected native snapshot stem, output prefix and optional --roundtrip");
    Verilated::commandArgs(argc,argv);Vzero_av_top top;
    VerilatedRestore state;state.open((std::string(argv[1])+".rtl").c_str());
    uint64_t cycle=0;state>>cycle;state>>top;state.close();
    auto* root=top.rootp;
    std::ofstream ram(std::string(argv[2])+"workram.bin",std::ios::binary);
    for(unsigned i=0;i<65536;++i) {
        const uint8_t bytes[2]={root->zero_av_top__DOT__board__DOT__ram_lo[i],
                                root->zero_av_top__DOT__board__DOT__ram_hi[i]};
        ram.write(reinterpret_cast<const char*>(bytes),2);
    }
    std::ofstream text(std::string(argv[2])+"text.bin",std::ios::binary);
    std::ofstream text_buffer(std::string(argv[2])+"textbuffer.bin",std::ios::binary);
    std::ofstream sprite(std::string(argv[2])+"sprite.bin",std::ios::binary);
    std::ofstream sprite_buffer(std::string(argv[2])+"spritebuffer.bin",std::ios::binary);
    for(unsigned i=0;i<2048;++i) {
        const uint8_t live[2]={root->zero_av_top__DOT__board__DOT__txt_lo[i],
                               root->zero_av_top__DOT__board__DOT__txt_hi[i]};
        const uint8_t buffered[2]={root->zero_av_top__DOT__board__DOT__txt_lo_buf[i],
                                   root->zero_av_top__DOT__board__DOT__txt_hi_buf[i]};
        text.write(reinterpret_cast<const char*>(live),2);
        text_buffer.write(reinterpret_cast<const char*>(buffered),2);
        const uint8_t spr_live[2]={root->zero_av_top__DOT__board__DOT__u_spr_bus__DOT__spr_lo[i],
                                   root->zero_av_top__DOT__board__DOT__u_spr_bus__DOT__spr_hi[i]};
        const uint8_t spr_buffered[2]={root->zero_av_top__DOT__board__DOT__u_spr_bus__DOT__spr_lo_buf[i],
                                       root->zero_av_top__DOT__board__DOT__u_spr_bus__DOT__spr_hi_buf[i]};
        sprite.write(reinterpret_cast<const char*>(spr_live),2);
        sprite_buffer.write(reinterpret_cast<const char*>(spr_buffered),2);
    }
    std::ofstream numeric(std::string(argv[2])+"numeric.json");
    numeric<<"{\"cycle\":"<<cycle
        <<",\"dips\":"<<top.dips<<",\"cabinet\":"<<(top.system_input&0x0700)
        <<",\"itoa_low\":"<<root->zero_av_top__DOT__board__DOT__u_cop3__DOT__cop_itoa_low
        <<",\"itoa_high\":"<<root->zero_av_top__DOT__board__DOT__u_cop3__DOT__cop_itoa_high
        <<",\"itoa_mode\":"<<root->zero_av_top__DOT__board__DOT__u_cop3__DOT__cop_itoa_mode
        <<",\"bcd_pending\":"<<int(root->zero_av_top__DOT__board__DOT__u_cop3__DOT__bcd_pending)
        <<",\"digits\":[";
    for(unsigned i=0;i<10;++i) {
        if(i)numeric<<",";
        numeric<<int(root->zero_av_top__DOT__board__DOT__u_cop3__DOT__cop_itoa_digits[i]);
    }
    numeric<<"]}\n";
    if(argc==4) {
        // Preserve every saved field without eval, reset or any clock edge.
        VerilatedSave roundtrip;roundtrip.open(std::string(argv[2])+"roundtrip.rtl");
        roundtrip<<cycle;roundtrip<<top;roundtrip.close();
    }
    std::ofstream crtc(std::string(argv[2])+"crtc.bin",std::ios::binary);
    for(unsigned i=0;i<40;++i) {
        auto word=root->zero_av_top__DOT__board__DOT__u_crtc__DOT__regs[i];
        const uint8_t bytes[2]={uint8_t(word),uint8_t(word>>8)};
        crtc.write(reinterpret_cast<const char*>(bytes),2);
    }
    std::ofstream report(std::string(argv[2])+"scroll.json");
    report<<"{\"cycle\":"<<cycle<<",\"latched_scroll\":{"
        <<"\"bg\":["<<root->zero_av_top__DOT__video__DOT__bg_layer__DOT__scroll_x_l<<","<<root->zero_av_top__DOT__video__DOT__bg_layer__DOT__scroll_y_l<<"],"
        <<"\"fg\":["<<root->zero_av_top__DOT__video__DOT__fg_layer__DOT__scroll_x_l<<","<<root->zero_av_top__DOT__video__DOT__fg_layer__DOT__scroll_y_l<<"],"
        <<"\"mg\":["<<root->zero_av_top__DOT__video__DOT__mg_layer__DOT__scroll_x_l<<","<<root->zero_av_top__DOT__video__DOT__mg_layer__DOT__scroll_y_l<<"]}}\n";
    std::cout<<"Read-only native work RAM/CRTC/scroll probe at cycle "<<cycle<<"\n";
}
