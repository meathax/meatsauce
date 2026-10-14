#include "Vzero_sdram_checks.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

// CAS latency counts through the first beat's launch edge (CL-1). A one-beat
// read stops driving after the next edge. Test both access and disable delays.
struct Event { uint64_t at; uint16_t value; };
int main(int argc, char** argv) {
    Verilated::commandArgs(argc,argv);
    Vzero_sdram_checks t;
    constexpr uint64_t period=10416, half=5208;
    const uint64_t access=argc>1 ? std::strtoull(argv[1],nullptr,10) : 6000;
    const uint64_t disable=argc>2 ? std::strtoull(argv[2],nullptr,10) : 3000;
    uint64_t now=0,cycles=0,reads=0,writes=0;
    unsigned cas=3,burst=0;
    uint16_t rows[4]{};
    std::map<unsigned,uint16_t> ram;
    std::vector<Event> pending;
    t.model_dq=0xdead;t.clk=0;t.clk_forward=0;t.init=1;t.request=0;t.write_mask=0;
    std::vector<uint64_t> read_edges;
    std::vector<unsigned> read_a10;
    t.length=0;
    auto advance=[&](uint64_t target,bool high,bool capture,bool sample_pins=false) {
        std::sort(pending.begin(),pending.end(),[](Event a,Event b){return a.at<b.at;});
        while(!pending.empty() && pending.front().at<=target) {
            now=pending.front().at;t.model_dq=pending.front().value;t.eval();
            pending.erase(pending.begin());
        }
        now=target;t.clk=high;t.clk_forward=capture;t.eval();
        if(sample_pins) {
            // Controller map: row = word address [21:9], column = [8:0].
            unsigned key=(unsigned(t.bank)<<22)|(unsigned(rows[t.bank])<<9)|(unsigned(t.pin_address)&511);
            switch(t.command) {
            case 3: rows[t.bank]=t.pin_address;break; // ACTIVE
            case 0: cas=(t.pin_address>>4)&7;burst=t.pin_address&7;break;
            case 5: // READ
                ++reads;
                read_edges.push_back(now);
                read_a10.push_back((t.pin_address>>10)&1);
                pending.push_back({now+(cas-1)*period+access,ram[key]});
                pending.push_back({now+cas*period+disable,0xdead});
                break;
            case 4: // WRITE
                ++writes;
                if(!(t.dqm&1))ram[key]=(ram[key]&0xff00)|(t.pin_write_data&255);
                if(!(t.dqm&2))ram[key]=(ram[key]&255)|(t.pin_write_data&0xff00);
                break;
            default:break;
            }
        }
    };
    auto tick=[&]() {
        advance(cycles*period,true,false);
        advance(cycles*period+1302,true,true); // 45-degree PLL source
        advance(cycles*period+half,false,true);
        advance(cycles*period+6510,false,false,true); // inverted clock: 225 degrees
        ++cycles;
    };
    for(unsigned n=0;n<10;++n)tick();t.init=0;
    for(unsigned n=0;n<40000 && !t.ready;++n)tick();
    if(!t.ready || cas!=3 || burst!=0){std::printf("Initialization failed ready=%u CAS=%u burst=%u\n",t.ready,cas,burst);return 1;}
    auto transfer=[&](unsigned port,unsigned addr,unsigned mask,unsigned data) {
        t.selected=port;t.address=addr;t.write_mask=mask;t.write_data=data;
        unsigned next=t.acknowledge^(1u<<port);t.request=next;
        for(unsigned n=0;n<100 && t.acknowledge!=next;++n)tick();
        if(t.acknowledge!=next){std::printf("Missing port %u acknowledgement\n",port);return false;}
        t.write_mask=0;return true;
    };
    unsigned checks=0;
    for(unsigned port=0;port<4;++port)for(unsigned n=0;n<16;++n) {
        unsigned addr=(port<<22)|(n*8193+0x123),value=0x4321+n*0x111;
        ram[addr]=value;
        if(!transfer(port,addr,0,0))return 1;
        ++checks;
        if(t.read_data!=value){std::printf("SDRAM valid-window FAIL port=%u address=%06x expected=%04x actual=%04x cycles=%llu tAC=%llu ps disable=%llu ps\n",port,addr,value,t.read_data,(unsigned long long)cycles,(unsigned long long)access,(unsigned long long)disable);return 2;}
        if(!transfer(port,addr,1,0xa5))return 1;
        if(!transfer(port,addr,0,0))return 1;
        ++checks;
        if(t.read_data!=((value&0xff00)|0xa5)){std::printf("Masked write FAIL\n");return 3;}
    }
    // Four held requests must retire once each, while the controller keeps
    // its eight-cycle command cadence despite the completion register stage.
    const unsigned burst_expected=t.read_data;
    const unsigned target_ack=t.acknowledge^15;
    const auto first_edge=read_edges.size();
    const auto before_reads=reads;
    t.write_mask=0;t.request=target_ack;
    for(unsigned n=0;n<100 && t.acknowledge!=target_ack;++n) {
        const unsigned old_ack=t.acknowledge;
        tick();
        const unsigned retired=t.acknowledge^old_ack;
        if(retired) {
            if((retired&(retired-1)) || t.read_data!=burst_expected) {
                std::printf("Concurrent request completion FAIL\n");return 4;
            }
            ++checks;
        }
    }
    if(t.acknowledge!=target_ack){std::printf("Concurrent request timeout\n");return 4;}
    for(unsigned n=0;n<12;++n)tick();
    if(reads!=before_reads+4){std::printf("Duplicate or missing transaction\n");return 4;}
    for(unsigned n=1;n<4;++n) {
        if(read_edges[first_edge+n]-read_edges[first_edge+n-1]!=8*period) {
            std::printf("Controller command cadence changed\n");return 4;
        }
    }
    // Port-0 multi-word reads: one ACTIVE, back-to-back READs one clock apart,
    // auto-precharge only on the last, every word inside its valid window.
    for(unsigned len=1;len<4;len+=2) for(unsigned group=0;group<8;++group) {
        const unsigned base=(1u<<22)|(group*0x2a9c0+0x44)|0;   // 4-word aligned
        for(unsigned w=0;w<=len;++w){ ram[base+w]=0x1000*(len+1)+group*0x10+w; }
        const auto first=read_edges.size();
        t.selected=0;t.address=base;t.write_mask=0;t.length=len;
        unsigned next=t.acknowledge^1u;t.request=next;
        std::vector<unsigned> got;
        for(unsigned n=0;n<100 && t.acknowledge!=next;++n){ tick(); if(t.beat) got.push_back(t.read_data); }
        t.length=0;
        if(t.acknowledge!=next || got.size()!=len+1){std::printf("Multi-word read FAIL len=%u beats=%zu\n",len,got.size());return 5;}
        for(unsigned w=0;w<=len;++w) if(got[w]!=ram[base+w]){
            std::printf("Multi-word valid-window FAIL len=%u word=%u expected=%04x actual=%04x tAC=%llu ps disable=%llu ps\n",
                len,w,ram[base+w],got[w],(unsigned long long)access,(unsigned long long)disable);return 2;}
        if(read_edges.size()-first!=len+1){std::printf("Multi-word READ count FAIL\n");return 5;}
        for(unsigned w=1;w<=len;++w) if(read_edges[first+w]-read_edges[first+w-1]!=period){std::printf("Multi-word READ cadence FAIL\n");return 5;}
        for(unsigned w=0;w<=len;++w) if(read_a10[first+w]!=(w==len)){std::printf("Auto-precharge placement FAIL\n");return 5;}
        checks+=len+1;
    }
    std::printf("SDRAM pin-window PASS checks=%u reads=%llu writes=%llu CAS=%u burst=%u period=%llu ps tAC=%llu ps disable=%llu ps command_cadence=8\n",checks,(unsigned long long)reads,(unsigned long long)writes,cas,burst,(unsigned long long)period,(unsigned long long)access,(unsigned long long)disable);
    return 0;
}
