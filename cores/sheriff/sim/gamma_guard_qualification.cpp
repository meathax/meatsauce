// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vn8080_gamma_guard.h"
#include "verilated.h"
#include <cstdlib>
#include <iostream>
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);Vn8080_gamma_guard b;
    b.clk=0;b.enable_requested=1;b.write_entry=0;b.write_address=767;b.eval();
    auto require=[&](bool expected){if(bool(b.enable_validated)!=expected){std::cerr<<"FAIL gamma gate\n";std::exit(1);}};
    auto tick=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};
    auto write=[&](unsigned address){b.write_address=address;b.write_entry=1;tick();b.write_entry=0;tick();};
    require(false);
    // Isolated last entry, idle clocks and interrupted upload cannot arm gamma.
    write(767);for(unsigned i=0;i<100;i++)tick();require(false);
    write(0);write(256);write(512);write(7);require(false);
    // Real Main_MiSTer ordering: bank addresses 0x000,0x100,0x200 per index.
    for(unsigned index=0;index<256;index++)for(unsigned channel=0;channel<3;channel++) {
        write((channel<<8)|index);require(index==255&&channel==2);
    }
    b.enable_requested=0;tick();require(false);
    b.enable_requested=1;tick();require(true);
    // A subsequent partial LUT update preserves the completed configuration.
    write(0);require(true);
    std::cout<<"PASS hostile enable/partial upload bypass, full768-entry upload, enable toggle and retained LUT\n";
}
