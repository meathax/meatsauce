#include "Valpha68kn_board.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>

// Real CPU diagnostic only: sound-chip readback is 0xff and no video engine
// participates. Compare every main-CPU counter with a full-system run before
// using these snapshots to explain a full-system difference.
struct Ports { uint16_t controls; uint8_t dips, coins; };
static std::vector<Ports> ports(const char* path) {
    std::ifstream in(path); if(!in) throw std::runtime_error("missing port trace");
    auto split=[](const std::string& line) {
        std::vector<std::string> out;std::istringstream s(line);std::string part;
        while(std::getline(s,part,',')) out.push_back(part);
        return out;
    };
    std::string line;std::getline(in,line);auto h=split(line);
    auto col=[&](const char* name) {
        auto i=std::find(h.begin(),h.end(),name);
        if(i==h.end()) throw std::runtime_error("missing port column");
        return unsigned(i-h.begin());
    };
    unsigned f=col("frame"),c=col("in0"),d=col("in1"),n=col("in2");
    std::vector<Ports> out;
    while(std::getline(in,line)) {
        auto v=split(line);if(v.size()!=h.size()) throw std::runtime_error("port row width");
        if(std::stoul(v[f])!=out.size()) throw std::runtime_error("port epoch");
        unsigned cv=std::stoul(v[c]),dv=std::stoul(v[d]),nv=std::stoul(v[n]);
        if(cv>65535 || dv>255 || nv>3) throw std::runtime_error("port value range");
        out.push_back({uint16_t(cv),uint8_t(dv),uint8_t(nv)});
    }
    return out;
}
int main(int argc,char** argv) try {
    if(argc!=5) {std::cerr<<"usage: board_state_sim download.bin fields output observed_ports.csv\n";return 2;}
    Verilated::commandArgs(argc,argv);
    std::ifstream in(argv[1],std::ios::binary);
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(in)),{});
    if(rom.size()!=0xa0000 || rom[0]!='A' || rom[5]>1) throw std::runtime_error("Kyros payload required");
    unsigned required=std::stoul(argv[2]);auto input=ports(argv[4]);
    if(!required || input.size()<required) throw std::runtime_error("insufficient observed ports");
    std::filesystem::path out(argv[3]);std::filesystem::create_directories(out);
    std::ofstream rows(out/"frames.csv"),writes(out/"sprite_writes.csv");
    rows<<"frame,main_transactions,work_writes,strip_writes,mcu_transactions,irq1_acks,irq2_acks,unmapped\n";
    writes<<"frame,tick,x,y,address,data,uds_n,lds_n\n";
    Valpha68kn_board b;b.clk=0;b.reset=1;b.downloading=1;b.load_wr=0;
    b.sound_io_read_data=255;b.controls=0;b.dips=0x8e;b.coins_n=3;
    b.debug_word_addr=0;b.debug_rom_kind=0;b.debug_rom_addr=0;
    auto tick=[&]() {b.clk=0;b.eval();b.clk=1;b.eval();};
    for(unsigned i=0;i<256;i++) tick();
    for(unsigned a=0;a<rom.size();a+=2) {b.load_wr=1;b.load_addr=a;b.load_data=rom[a]|(rom[a+1]<<8);tick();}
    b.load_wr=0;b.downloading=0;for(unsigned i=0;i<4096;i++) tick();
    auto set_ports=[&](unsigned f) {b.controls=input[f].controls;b.dips=input[f].dips;b.coins_n=input[f].coins;};
    set_ports(0);b.reset=0;uint64_t ticks=0;unsigned frame=0;uint32_t transactions=0;
    while(frame<required) {
        if(ticks>uint64_t(required+1)*384*264*8) throw std::runtime_error("raster timeout");
        bool boundary=b.ce_pix && b.x==383 && b.y==239;
        auto addr=b.debug_main_addr;auto data=b.debug_main_dout;auto attrs=b.debug_main_attrs;
        auto x=b.x,y=b.y;tick();ticks++;
        if(b.main_transactions!=transactions) {
            transactions=b.main_transactions;
            if(frame>=895 && addr>=0x40000 && addr<0x42000 && !(attrs&4))
                writes<<frame<<','<<ticks<<','<<x<<','<<y<<','<<addr<<','<<data<<','<<((attrs>>1)&1)<<','<<(attrs&1)<<'\n';
        }
        if(!boundary) continue;
        rows<<frame<<','<<b.main_transactions<<','<<b.work_writes<<','<<b.strip_writes<<','
            <<b.mcu_transactions<<','<<b.irq1_acks<<','<<b.irq2_acks<<','<<b.unmapped_accesses<<'\n';rows.flush();
        if(frame%90==0) std::cout<<"frame="<<frame<<" main="<<b.main_transactions<<std::endl;
        set_ports(frame);frame++;
    }
    b.reset=1;tick();std::ofstream work(out/"work.bin",std::ios::binary),strip(out/"sprites.bin",std::ios::binary);
    for(unsigned a=0;a<4096;a++) {
        b.debug_word_addr=a;tick();auto w=b.debug_work_data,s=b.debug_strip_data;
        if(a<2048) {work.put(w>>8);work.put(w);}strip.put(s>>8);strip.put(s);
    }
    std::cout<<"completed_fields="<<frame<<" unmapped="<<b.unmapped_accesses<<std::endl;
    b.final();return b.unmapped_accesses ? 1 : 0;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
