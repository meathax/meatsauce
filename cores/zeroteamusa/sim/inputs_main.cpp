#include "Vzero_inputs_top.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv); Vzero_inputs_top t;
    auto tick=[&](){t.clk=0;t.eval();t.clk=1;t.eval();};
    unsigned checks=0;
    auto check=[&](unsigned a,unsigned b,unsigned c,unsigned d,unsigned coin,unsigned system){
        t.eval();
        if(t.p1!=a||t.p2!=b||t.p3!=c||t.p4!=d||t.coin!=coin||t.system_port!=system)
            throw std::runtime_error("Target input vector failed: "+std::to_string(checks));
        ++checks;
    };
    bool toggle=false;
    auto key=[&](unsigned code,bool down){toggle=!toggle;t.ps2_key=(toggle?1024:0)|(down?512:0)|code;tick();};
    t.pad0=t.pad1=t.pad2=t.pad3=0;t.ps2_key=0;t.system_config=0xffff;
    t.reset=1;tick();t.reset=0;tick();check(255,255,255,255,255,0xffff);
    t.system_config=0xfdff;check(255,255,255,255,255,0xfdff);
    t.pad0=t.pad1=t.pad2=t.pad3=0x400;check(255,255,255,255,255,0xfdcc);
    t.pad0=t.pad1=t.pad2=t.pad3=0;t.pad3=0x800;check(255,255,255,255,0xf7,0xfdff);
    t.pad3=0;t.pad2=0x40;check(255,255,0xff,255,255,0xfdff);
    t.pad2=0;t.pad0=0x11;check(0xe7,255,255,255,255,0xfdff);
    t.pad0=0;
    key(0x16b,true);check(0xfb,255,255,255,255,0xfdff);
    key(0x06b,true);check(0xfb,255,255,0xfb,255,0xfdff);
    key(0x16b,false);check(255,255,255,0xfb,255,0xfdff);
    key(0x06b,false);check(255,255,255,255,255,0xfdff);
    key(0x26,true);key(0x25,true);check(255,255,255,255,255,0xfdcf);
    key(0x26,false);key(0x25,false);key(0x3d,true);key(0x3e,true);
    check(255,255,255,255,0xf3,0xfdff);
    key(0x3d,false);key(0x3e,false);key(0x06,true);check(255,255,255,255,255,0xfdf7);
    key(0x06,false);key(0x04,true);check(255,255,255,255,255,0xf5ff);
    key(0x04,false);key(0x1a,true);key(0x22,true);check(255,0xcf,255,255,255,0xfdff);
    key(0x32,true);key(0x31,true);check(255,0xcf,0xcf,255,255,0xfdff);
    t.reset=1;tick();t.reset=0;tick();check(255,255,255,255,255,0xfdff);
    for(unsigned cabinet=0;cabinet<8;++cabinet) {
        t.system_config=0xf8ff|(cabinet<<8);
        check(255,255,255,255,255,t.system_config);
    }
    for(unsigned bit=11;bit<16;++bit) {
        t.system_config=0xffff&~(1u<<bit);
        check(255,255,255,255,255,t.system_config);
    }
    std::ofstream report("sim/results/inputs-front-end.json");
    report<<"{\"vectors\": "<<checks<<", \"failures\": 0}\n";
    std::cout<<"Target frontend vectors="<<checks<<" failures=0\n";
}
