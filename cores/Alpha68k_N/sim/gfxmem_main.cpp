#include "Valpha68kn_gfxmem.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

// Pin-level SDR SDRAM model: commands are sampled on the forwarded half-cycle.
// CL=2, burst=1, four banks, 512 columns. This models the external device only.
struct Sdram {
    std::vector<uint16_t> memory=std::vector<uint16_t>(1u<<24,0xaaaa);
    std::vector<uint8_t> written=std::vector<uint8_t>(0x60000,0);
    std::array<int,4> row{{-1,-1,-1,-1}};
    std::array<uint64_t,4> active{},precharged{};
    uint64_t cycle=0,writes=0,reads=0,refreshes=0,modes=0;
    uint16_t dq=0;
    struct Pending {uint64_t due;unsigned address;};
    std::vector<Pending> pending;
    void sample(Valpha68kn_gfxmem& top) {
        ++cycle;
        for(auto it=pending.begin();it!=pending.end();) {
            if(it->due==cycle) {dq=memory.at(it->address);it=pending.erase(it);}
            else ++it;
        }
        if(!top.sdram_cke) return;
        unsigned cmd=(top.sdram_ncs<<3)|(top.sdram_nras<<2)|(top.sdram_ncas<<1)|top.sdram_nwe;
        unsigned bank=top.sdram_ba,a=top.sdram_a;
        if(cmd==3) {
            if(row[bank]!=-1 || cycle-precharged[bank]<1)
                throw std::runtime_error("SDRAM ACTIVE without precharge");
            row[bank]=a; active[bank]=cycle;
        } else if(cmd==2) {
            if(a&0x400) for(unsigned b=0;b<4;b++) {row[b]=-1;precharged[b]=cycle;}
            else {row[bank]=-1;precharged[bank]=cycle;}
        } else if(cmd==0) {
            if((a&7)!=0 || ((a>>4)&7)!=2)
                throw std::runtime_error("unexpected SDRAM burst/CAS mode: cycle="+std::to_string(cycle)+" address="+std::to_string(a));
            modes++;
        } else if(cmd==1) {
            for(auto r:row) if(r!=-1) throw std::runtime_error("refresh with active row");
            refreshes++;
        } else if(cmd==4 || cmd==5) {
            if(row[bank]<0 || cycle-active[bank]<1)
                throw std::runtime_error("SDRAM access before ACTIVE/tRCD");
            unsigned address=(bank<<22)|(unsigned(row[bank])<<9)|(a&511);
            if(cmd==4) {
                uint16_t word=memory.at(address);
                if(!top.sdram_dqml) word=(word&0xff00)|(top.sdram_din&255);
                if(!top.sdram_dqmh) word=(word&0x00ff)|(top.sdram_din&0xff00);
                memory[address]=word;
                if(address*2<written.size()) {
                    if(!top.sdram_dqml) written[address*2]++;
                    if(!top.sdram_dqmh) written[address*2+1]++;
                }
                writes++;
            } else {pending.push_back({cycle+2,address});reads++;}
            if(a&0x400) {row[bank]=-1;precharged[bank]=cycle;}
        }
    }
};
unsigned swizzle(unsigned raw) {
    return (raw&~9u)|((raw&1)<<3)|((raw&8)>>3);
}
int main(int argc,char** argv) {
    try {
        if(argc!=2) throw std::runtime_error("usage: gfxmem_sim download.bin");
        Verilated::commandArgs(argc,argv);
        std::ifstream image(argv[1],std::ios::binary);
        std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(image)),{});
        if(bytes.size()!=0xa0000) throw std::runtime_error("invalid image size");
        Valpha68kn_gfxmem top;
        Sdram device;
        top.clk=0;top.reset=1;top.load_wr=0;top.refresh=0;top.read_req=0;
        top.load_addr=0;top.load_data=0;top.read_addr=0;top.sdram_dq=0;
        // Settle the first registered reset/NOP before the SDRAM clock starts.
        top.eval();
        for(unsigned i=0;i<2;i++) {top.clk=1;top.eval();top.clk=0;top.eval();}
        uint64_t ticks=0;
        auto tick=[&]() {
            top.clk=0;top.eval();
            device.sample(top);
            top.sdram_dq=device.dq;top.eval();
            top.refresh=(ticks%3072)==3071;
            top.clk=1;top.eval();++ticks;
        };
        for(unsigned i=0;i<10000;i++) tick();
        top.reset=0;
        for(unsigned i=0;!top.initialized;i++) {
            if(i>30000) throw std::runtime_error("SDRAM initialization timeout");
            tick();
        }
        uint64_t start=ticks;
        for(unsigned raw=0;raw<0x60000;raw+=2) {
            top.load_wr=0;
            while(top.load_wait) tick();
            top.load_addr=raw;
            top.load_data=bytes[0x40000+raw]|(bytes[0x40001+raw]<<8);
            top.load_wr=1;tick();
        }
        top.load_wr=0;
        for(unsigned i=0;top.load_busy;i++) {
            if(i>10000) throw std::runtime_error("download drain timeout");
            tick();
        }
        if(device.writes!=0x60000 || device.modes!=1 || device.refreshes<3)
            throw std::runtime_error("incorrect SDRAM command counts");
        if(top.loaded_words!=0x30000) throw std::runtime_error("lost download word");
        for(unsigned raw=0;raw<0x60000;raw++) {
            unsigned p=swizzle(raw);
            uint8_t actual=(device.memory[p/2]>>(8*(p&1)))&255;
            if(actual!=bytes[0x40000+raw] || device.written[p]!=1)
                throw std::runtime_error("SDRAM byte/mask/address mismatch at "+std::to_string(raw));
        }
        uint64_t download_cycles=ticks-start;
        unsigned checked=0,max_latency=0;
        // Each tile row's two physical bytes, with explicit plane/bank boundaries.
        for(unsigned raw=0;raw<0x60000;raw+=16) {
            raw+=checked%8; // cover all row offsets; bit 3 stays zero
            top.read_addr=raw;top.read_req=1;
            unsigned latency=0;
            bool done=false,acked=false;
            while(!done) {
                tick();++latency;
                if(top.read_ack) {top.read_req=0;acked=true;}
                if(top.read_ready) {
                    if(!acked) throw std::runtime_error("ready before read acknowledgment");
                    done=true;
                }
                if(latency>200) throw std::runtime_error("SDRAM read timeout");
            }
            uint16_t expected=bytes[0x40000+(raw&~8u)]|
                (uint16_t(bytes[0x40000+(raw|8u)])<<8);
            if(top.read_data!=expected)
                throw std::runtime_error("row pair mismatch at "+std::to_string(raw));
            if(latency>max_latency) max_latency=latency;
            checked++;raw-=((checked-1)%8);
            tick();
        }
        if(device.reads!=checked) throw std::runtime_error("duplicate or lost SDRAM read");
        std::cout<<"{\"download_words\":"<<top.loaded_words
            <<",\"physical_writes\":"<<device.writes<<",\"checked_bytes\":393216"
            <<",\"read_pairs\":"<<checked<<",\"max_read_cycles\":"<<max_latency
            <<",\"refresh_commands\":"<<device.refreshes<<",\"mode_commands\":"<<device.modes
            <<",\"download_cycles\":"<<download_cycles<<",\"result\":\"pass\"}\n";
        top.final();return 0;
    } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
}
