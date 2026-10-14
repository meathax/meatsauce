#include "Vzero_platform_boot.h"
#include "verilated.h"
#include <array>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);Vzero_platform_boot t;
    std::ifstream file("roms/regions/maincpu.bin",std::ios::binary);
    std::vector<unsigned char> rom{std::istreambuf_iterator<char>(file),{}};
    if(rom.size()!=0x100000)throw std::runtime_error("Need exact local US program region");
    struct Port {bool pending=false,token=false;unsigned due=0,address=0;};
    std::array<Port,2> p;uint64_t clock=0,reads=0,writes=0,irqs=0,frames=0;
    bool previous_write=false,previous_irq=false,previous_vblank=false;
    auto tick=[&](){
        t.clk=0;t.eval();
        for(int i=0;i<2;i++) {
            bool req=i==0?t.main_req:t.cop_req,ack=i==0?t.main_ack:t.cop_ack;
            auto& q=p[i];
            if(!q.pending && req!=ack) {
                q.pending=true;q.token=req;q.due=16;
                q.address=i==0?t.main_address:t.cop_address;++reads;
                if(q.address>=rom.size()/2)throw std::runtime_error("CPU/COP bridge read outside US program region");
            }
            if(q.pending && --q.due==0) {
                unsigned value=rom[q.address*2]|(unsigned(rom[q.address*2+1])<<8);
                if(i==0){t.main_data=value;t.main_ack=q.token;}
                else {t.cop_data=value;t.cop_ack=q.token;}
                q.pending=false;
            }
        }
        t.clk=1;t.eval();++clock;
        if(t.cpu_write && !previous_write)++writes;
        if(t.irq_ack && !previous_irq)++irqs;
        if(t.vblank && !previous_vblank)++frames;
        previous_write=t.cpu_write;previous_irq=t.irq_ack;previous_vblank=t.vblank;
    };
    t.reset=1;for(int i=0;i<60;i++)tick();t.reset=0;
    while(frames<60)tick();
    t.pause=1;
    for(unsigned n=0;n<10000 && t.cop_busy;n++)tick();
    if(t.cop_busy)throw std::runtime_error("COP did not drain at observation boundary");
    unsigned text_nonzero=0,palette_nonzero=0;
    for(unsigned a=0;a<2048;a++) {
        t.probe=a;for(int n=0;n<3;n++)tick();
        text_nonzero+=t.text_data!=0;palette_nonzero+=t.palette_data!=0;
    }
    if(reads<1000000 || writes<10000 || irqs<50 || !text_nonzero || !palette_nonzero)
        throw std::runtime_error("Native bridge did not reach meaningful target boot: reads="+std::to_string(reads)+
            " writes="+std::to_string(writes)+" IRQs="+std::to_string(irqs)+
            " text="+std::to_string(text_nonzero)+" palette="+std::to_string(palette_nonzero));
    std::ofstream out("sim/results/platform-boot.json");
    out<<"{\"frames\":"<<frames<<",\"system_cycles\":"<<clock<<",\"memory_latency\":16,\"rom_reads\":"<<reads
       <<",\"cpu_writes\":"<<writes<<",\"interrupts\":"<<irqs<<",\"text_nonzero\":"<<text_nonzero
       <<",\"palette_nonzero\":"<<palette_nonzero<<",\"failures\":0}\n";
    std::cout<<"Native bridge boot passed: frames="<<frames<<" reads="<<reads<<" writes="<<writes
             <<" IRQs="<<irqs<<" text="<<text_nonzero<<" palette="<<palette_nonzero<<"\n";
}
