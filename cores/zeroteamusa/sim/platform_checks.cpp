#include "Vzero_platform_checks.h"
#include "verilated.h"
#include <array>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <vector>
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv); Vzero_platform_checks t;
    unsigned checks=0;uint64_t clocks=0;int pause_delay=0;
    auto require=[&](bool ok,const char* what){++checks;if(!ok)throw std::runtime_error(what);};
    // Port 0 returns len0+1 consecutive words, one beat0 strobe each, and
    // acknowledges with the last (sdram.sv multi-word read contract).
    struct Port {bool busy=false,target=false;unsigned timer=0,address=0;bool write=false;unsigned data=0,words=1,beat=0;};
    std::array<Port,4> p;std::map<unsigned,unsigned> mem;
    auto tick=[&](){
        t.clk=0;t.eval();
        t.beat0=0;
        for(int i=0;i<4;i++) {
            bool req=i==0?t.req0:i==1?t.req1:i==2?t.req2:t.req3;
            bool ack=i==0?t.ack0:i==1?t.ack1:i==2?t.ack2:t.ack3;
            auto& q=p[i];
            if(!q.busy && req!=ack) {
                q.busy=true;q.target=req;q.timer=7+i*3;
                q.address=i==0?t.addr0:i==1?t.addr1:i==2?t.addr2:t.addr3;
                q.write=i==0 && t.we0;q.data=t.din0;
                q.words=(i==0 && !q.write)?t.len0+1u:1u;q.beat=0;
            }
            if(q.busy && i==0 && q.timer==0) {   // remaining beats, one per clock
                t.dout0=mem[q.address+q.beat];t.beat0=1;
                if(++q.beat==q.words){t.ack0=q.target;q.busy=false;}
                continue;
            }
            if(q.busy && --q.timer==0) {
                if(q.write)mem[q.address]=q.data;
                if(i==0 && !q.write) {
                    t.dout0=mem[q.address];t.beat0=1;
                    if(++q.beat<q.words) continue;   // more beats on the next clocks
                }
                unsigned value=mem[q.address];
                if(i==0){t.ack0=q.target;t.dout0=value;}
                if(i==1){t.ack1=q.target;t.dout1=value;}
                if(i==2){t.ack2=q.target;t.dout2=value;}
                if(i==3){t.ack3=q.target;t.dout3=value;}
                q.busy=false;
            }
        }
        if(t.hs_pause) {if(pause_delay<200)++pause_delay;t.hs_paused=pause_delay>=200;}
        else {pause_delay=0;t.hs_paused=0;}
        t.clk=1;t.eval();++clocks;
    };
    auto run=[&](unsigned n){while(n--)tick();};
    t.ready=1;t.reset=1;t.hs_reset=1;run(3);t.reset=0;run(3);
    auto send=[&](unsigned a,unsigned byte){
        for(unsigned n=0;t.wait_hps && n<200;n++)tick();
        require(!t.wait_hps,"HPS wait stuck");t.address=a;t.data=byte;t.wr=1;tick();t.wr=0;tick();
    };
    auto word=[&](unsigned a,unsigned value){t.download=1;t.index=0;send(a,value&255);send(a+1,value>>8);};
    word(0x1234,0x1234);word(0x100000,0x5678);word(0x120000,0xaabb);word(0x120002,0xccdd);
    word(0x520000,0x3412);word(0x600000,0x8877);word(0x600002,0xaa99);word(0xdffffe,0xbeef);
    t.download=0;run(80);
    require(mem[0x91a]==0x1234,"main download LE packing");
    require(mem[0x400000]==0x8877 && mem[0x7fffff]==0xbeef,"sprite bank/range mapping");
    require(mem[0x80000]==0x5678,"character ROM packing");
    require(!t.download_busy,"last write did not drain");
    auto gfx=[&](unsigned kind,unsigned a,unsigned expected){
        t.gfx_kind=kind;t.gfx_address=a;t.gfx_req=1;
        for(unsigned n=0;n<100 && !t.gfx_valid;n++)tick();
        require(t.gfx_valid && t.gfx_data==expected,"graphics packing/response");
        require(!t.download_busy,"graphics incorrectly asserts ROM reset hold");
        t.gfx_req=0;run(3);
    };
    gfx(0,0,0xaabbccdd);gfx(1,0,0xaabbccdd);gfx(2,0,0xaabbccdd);gfx(3,0,0xaa998877);
    // Dedicated sprite row port: 8 bytes -> two native LE32 halves in order.
    mem[0x400002]=0x2211;mem[0x400003]=0x4433;
    {
        t.spr_address=0;t.spr_req=1;unsigned got=0;uint32_t h[2]={0,0};
        for(unsigned n=0;n<100 && got<2;n++){tick();if(t.spr_valid){require(t.spr_half==got,"sprite half order");h[got++]=t.spr_data;}}
        require(got==2 && h[0]==0xaa998877u && h[1]==0x44332211u,"sprite row packing/response");
        t.spr_req=0;run(3);
        // A request dropped before its data arrives must not deliver a stale row.
        t.spr_req=1;tick();t.spr_req=0;bool stale=false;
        for(unsigned n=0;n<60;n++){tick();stale|=t.spr_valid;}
        require(!stale,"cancelled sprite row delivered");
        // Sprite and tile requests together: both complete (tile pulse latched).
        t.spr_address=0;t.spr_req=1;t.gfx_kind=0;t.gfx_address=0;t.gfx_req=1;tick();t.gfx_req=0;
        bool tile=false;got=0;
        for(unsigned n=0;n<200 && !(tile && got==2);n++){tick();if(t.gfx_valid){tile=true;require(t.gfx_data==0xaabbccdd,"tile during sprite");}if(t.spr_valid)++got;}
        require(tile && got==2,"concurrent sprite/tile requests");
        t.spr_req=0;run(3);
    }
    t.main_address=t.cop_address=0x1234;t.main_req=t.cop_req=1;
    bool main_ok=false,cop_ok=false;
    for(unsigned n=0;n<100;n++){tick();if(t.main_valid)main_ok=t.main_data==0x1234;if(t.cop_valid)cop_ok=t.cop_data==0x1234;}
    require(main_ok && cop_ok,"simultaneous main/COP reads");t.main_req=t.cop_req=0;
    t.main_address=0x100000;run(80);
    require(!t.main_valid && t.main_data==0x5678,"V30 falling toggle acknowledgement");
    t.oki_address=1;run(80);require(t.oki_valid && t.oki_data==0x34,"OKI odd byte");
    t.oki_address=0;run(80);require(t.oki_valid && t.oki_data==0x12,"OKI even byte");
    // Same pixel interval and whole raster even with legacy 60 Hz input asserted.
    for(int mode=0;mode<2;mode++) {
        t.mode_60hz=mode;t.reset=1;run(2);t.reset=0;
        while(!(t.ce_pixel && t.hpos==0 && t.vpos==0))tick();
        uint64_t start=clocks,last=start;unsigned pixels=0,active=0,sync_pixels=0,sync_lines=0;
        do {
            tick();if(t.ce_pixel) {
                require(clocks-last==12,"nonuniform direct-video pixel enable");last=clocks;
                ++pixels;active+=t.de;sync_pixels+=t.hsync;
                if(t.hpos==0 && t.vsync)++sync_lines;
                require(!(t.hsync && !t.hblank),"HSync overlaps active pixels");
                require(!(t.vsync && !t.vblank),"VSync overlaps active lines");
            }
        } while(!(t.ce_pixel && t.hpos==0 && t.vpos==0));
        require(clocks-start==1732608 && pixels==144384 && active==81920,"native raster/refresh");
        require(sync_pixels==38*282 && sync_lines==3,"sync widths");
    }
    // Real board work-RAM tap, including byte-lane preservation.
    auto ram_write=[&](unsigned a,unsigned value){t.test_ram_access=1;t.test_ram_write=1;t.test_ram_address=a;t.test_ram_data=value;tick();t.test_ram_write=0;run(2);};
    auto ram_read=[&](unsigned a){t.test_ram_access=1;t.test_ram_write=0;t.test_ram_address=a;run(3);return unsigned(t.test_ram_q);};
    std::vector<unsigned> saved(75);
    for(unsigned i=0;i<75;i++){ram_write(0x9212+i,i==0?0x40:i==74?0x55:0);saved[i]=0x80+i;}
    require(ram_read(0x9212)==0x40 && ram_read(0x925c)==0x55,"sentinel fixture");
    ram_write(0x9213,0x6a);require(ram_read(0x9212)==0x40 && ram_read(0x9213)==0x6a,"little-endian lane isolation");
    t.test_ram_access=0;
    std::vector<unsigned> cfg={0,0,0,32,0x3f,0xff,0,4,0,4,0,1,0,15,16,0,0,0,0x92,0x12,0x4b,0x40,0x55,0};
    t.download=1;t.index=3;for(unsigned i=0;i<cfg.size();i++)send(i,cfg[i]);t.download=0;run(5);
    require(t.hs_configured,"highscore config not parsed in byte mode");
    t.download=1;t.index=4;for(unsigned i=0;i<75;i++)send(i,saved[i]);t.download=0;run(5);
    t.hs_reset=0;run(5000);
    for(unsigned i=0;i<75;i++)require(ram_read(0x9212+i)==saved[i],"75-byte score restore or read latency");
    // Saving must work after restore has changed the initialization signatures.
    saved[17]=0x42;ram_write(0x9223,0x42);t.test_ram_access=0;
    t.hs_osd=1;bool requested=false;
    for(unsigned n=0;n<5000;n++){tick();requested|=t.hs_upload_req;}
    require(requested,"opening OSD did not request highscore autosave");
    t.hs_upload=1;t.index=4;run(4);
    for(unsigned i=0;i<75;i++){t.address=i;run(4);require(t.hs_upload_data==saved[i],"uploaded score bytes differ");}
    t.hs_upload=0;t.hs_osd=0;run(10);t.hs_osd=1;requested=false;
    for(unsigned n=0;n<5000;n++){tick();requested|=t.hs_upload_req;}
    require(!requested,"unchanged scores triggered duplicate upload");t.hs_osd=0;
    // Delayed pause acknowledgement must hold the hiscore state machine.
    saved[18]=0x43;ram_write(0x9224,0x43);t.test_ram_access=0;t.hs_osd=1;
    for(unsigned n=0;n<100;n++){tick();require(!t.hs_upload_req,"save ran before CPU/COP pause acknowledgement");}
    run(5000);t.hs_osd=0;
    // DDR FIFO under variable stalls, with exactly preserved address/data/BE.
    std::deque<std::array<uint64_t,3>> expected;unsigned received=0;
    for(unsigned n=0;n<8000;n++) {
        t.rotation_write=n<5000 && n%12==0;t.rotation_busy=n%73<49;
        t.rotation_address=n;t.rotation_data=(uint64_t(n)<<32)|n;t.rotation_be=n%24?0xf0:0x0f;
        if(t.rotation_write)expected.push_back({n,n,t.rotation_be});
        t.clk=0;t.eval();
        if(t.ddr_write) {
            require(!expected.empty(),"rotation FIFO extra write");auto e=expected.front();expected.pop_front();
            require(t.ddr_address==e[0] && uint32_t(t.ddr_data)==e[1] && t.ddr_be==e[2],"rotation FIFO ordering/backpressure");++received;
        }
        tick();
    }
    require(expected.empty() && received==417 && !t.rotation_overflow,"rotation FIFO drain");
    std::ofstream out("sim/results/platform-checks.json");
    out<<"{\"checks\":"<<checks<<",\"failures\":0,\"frame_cycles\":1732608,\"refresh_hz\":55.40780141843972,\"highscore_bytes\":75,\"rotation_writes\":"<<received<<"}\n";
    std::cout<<"Platform RTL checks="<<checks<<" failures=0; raster, memory, score roundtrip, DDR stalls passed\n";
}
