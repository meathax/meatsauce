// SPDX-License-Identifier: GPL-3.0-or-later
// GPU line-burst path through the real arbiter/fabric/SDRAM controller while the display scans
// out and a CPU-like peer reads work RAM. Two parts:
//  1. the staged native first-draw packet (docs/mame_gpu_fixture.json);
//  2. whole real game frames captured from MAME 0.289 (docs/mame_gpu_frames.json): texture and
//     frame RAM at the frame start, then every CPU/DMA RAM write, GPU register write and
//     vblank in order. The pinned MAME drawing code (vr0_gpu_reference.hpp) runs the same
//     queue with MAME's pipeline/flip rules; the whole frame RAM read back from the physical
//     SDRAM model must equal it, and the display must never underrun.
// Render cost = clocks the GPU engine is busy (not idle/flip-blocked), reported per real frame
// against the 60 Hz budget (85.90908 MHz / 60 = 1,431,818 clocks).
#include "Vcs_gpu_fabric.h"
#include "verilated.h"
#include "../memory/sdram_model.hpp"
#include "../memory/ddr_model.hpp"
#include "../obj_dir/gpu_reference/vr0_gpu_reference.hpp"
#include <array>
#include <map>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
double sc_time_stamp(){return 0;}
static constexpr double FRAME_BUDGET=85909080.0/60.0;
// sdram_axi_core byte address -> model halfword index (COL_W 9, 4 banks, 13 row bits).
static uint32_t model_index(uint32_t physical){
    return ((physical>>12)<<11)|(((physical>>10)&3)<<9)|(((physical>>2)&0xff)<<1)|((physical>>1)&1);
}
static constexpr uint32_t TEXTURE_BASE=0x00800000,FRAME_BASE=0x01000000;
static void check(bool x,const char*t){if(!x)throw std::runtime_error(t);}
enum {S_IDLE,S_RD_LOOKUP,S_RD_CHECK,S_RD_FILL,S_RD_FILL_WAIT,S_PACKET_STORE,S_DECODE,S_PREP,S_PAL_STORE,S_PIX_START,
    S_PIXELS,S_RELOOK,S_DEST_LOAD,S_DEST_WAIT,S_COMPLETE,S_FAILED,S_COUNT,S_PIXELS_STALL_WRITE=S_COUNT,S_PIXELS_DRAIN,S_STAT_COUNT};
static const char* state_names[S_COUNT]={"IDLE","RD_LOOKUP","RD_CHECK","RD_FILL","RD_FILL_WAIT","PACKET_STORE","DECODE","PREP",
    "PAL_STORE","PIX_START","PIXELS","RELOOK","DEST_LOAD","DEST_WAIT","COMPLETE","FAILED"};
static const char* stat_names[S_STAT_COUNT]={"IDLE","RD_LOOKUP","RD_CHECK","RD_FILL","RD_FILL_WAIT","PACKET_STORE","DECODE","PREP",
    "PAL_STORE","PIX_START","PIXELS(advancing)","RELOOK","DEST_LOAD","DEST_WAIT","COMPLETE","FAILED","PIXELS(write stall)","PIXELS(other)"};

struct Bench {
    Vcs_gpu_fabric d;SdramModel s;DdrModel memory;
    // CPU-like peer: 0 none; 1 saturating (a work-RAM read in every free slot, mostly line
    // misses: ~40% of SDRAM time, far above the CPU's cached traffic, the stress case);
    // 2 sparse (a random work-RAM read every ~64 clocks on average, still ~30x the original
    // ROM's measured CPU cache-miss rate of ~1 per 3000 clocks, physical_boot CP0 counters).
    bool line_busy=false;uint64_t line_begin=0,line_max=0,line_total=0,lines=0;int peer_mode=1;bool pending=false;uint32_t peer_rng=0x2468ace1;const char* phase="init";bool scan_wait=false;uint64_t scan_begin=0,scan_max=0;std::array<uint64_t,16> scan_hist{};
    uint64_t clock=0,accepted=0,responses=0,begin=0,max_latency=0,pixels=0,busy=0;unsigned frames=0;
    std::array<uint64_t,S_STAT_COUNT> state_clocks{};uint64_t burst_reads=0,burst_writes=0,burst_dest_reads=0,fill_fsm=0,fill_a=0,fill_b=0;
    uint64_t pf_acc=0,pf_used=0;
    uint32_t last_a=0,last_b=0;uint64_t seq_a=0,seq_b=0;
    uint64_t be_write=0,be_dest=0,be_fill=0,be_word=0,be_activates=0,be_columns=0;
    void finish(){memory.finish(d);d.sdram_data_in=s.tick(d.sdram_cke,d.sdram_cs_n,d.sdram_ras_n,d.sdram_cas_n,d.sdram_we_n,d.sdram_ba,d.sdram_address,d.sdram_dqm,d.sdram_data_out,d.sdram_data_oe);d.eval();}
    // One board clock with live scanout and a CPU-like peer streaming work-RAM reads.
    void step(){
        if(peer_mode==2){
            if(pending)d.peer_valid=0;
            else if(!d.peer_valid){peer_rng^=peer_rng<<13;peer_rng^=peer_rng>>17;peer_rng^=peer_rng<<5;
                if((peer_rng&63)==0){d.peer_valid=1;d.peer_address=0x02000000+((peer_rng>>6)&0x7ffffc);}}
        }else{
            d.peer_valid=peer_mode==1&&!pending;
            d.peer_address=0x02000000+uint32_t((accepted/8*0x1020+(accepted%8)*4)&0x7ffffc);
        }
        memory.prepare(d);
        const bool take=d.peer_valid&&d.peer_ready,reply=d.peer_rsp_valid;
        if(reply){check(pending,"lost peer response");check(!d.peer_rsp_error,"peer memory error");++responses;max_latency=std::max(max_latency,clock-begin);pending=false;}
        if(take){pending=true;begin=clock;++accepted;}
        if(d.video_tick&&d.video_de&&d.video_armed){++pixels;if(d.video_x==319&&d.video_y==239)++frames;}
        check(!d.video_fault,"scanout physical memory error");
        if(d.video_underrun){std::fprintf(stderr,"underrun at clock %llu phase %s gpu state %s busy=%d frames=%u pixels=%llu x=%u y=%u\n",(unsigned long long)clock,phase,state_names[d.stat_gpu_state%S_COUNT],int(d.gpu_busy),frames,(unsigned long long)pixels,unsigned(d.video_x),unsigned(d.video_y));
            for(unsigned i=0;i<16;i++)std::fprintf(stderr," [%u..]=%llu",i*8,(unsigned long long)scan_hist[i]);std::fprintf(stderr," max=%llu\n",(unsigned long long)scan_max);
            throw std::runtime_error("display underrun while the GPU renders through the burst path");}
        check(!d.gpu_fault,"GPU memory fault");
        // Display line-fetch time (launch to line complete) against the 5460-clock line period.
        if(d.stat_scan_fetching){if(!line_busy){line_busy=true;line_begin=clock;}}
        else if(line_busy){line_busy=false;const uint64_t l=clock-line_begin;++lines;line_total+=l;if(l>line_max)line_max=l;}
        if(d.stat_scan_valid&&!scan_wait){scan_wait=true;scan_begin=clock;}
        if(d.stat_scan_rsp&&scan_wait){scan_wait=false;const uint64_t l=clock-scan_begin;scan_hist[std::min<uint64_t>(l/8,15)]++;if(l>scan_max)scan_max=l;}
        if(d.stat_be_bursting){if(d.stat_be_burst_write)++be_write;else if(d.stat_be_burst_frame)++be_dest;else ++be_fill;}
        else if(d.stat_be_busy)++be_word;
        if(d.stat_pf_accept)++pf_acc;if(d.stat_pf_used)++pf_used;
        if(d.stat_be_cmd_act)++be_activates;
        if(d.stat_be_cmd_rw)++be_columns;
        if(d.gpu_busy){++busy;
            unsigned st=d.stat_gpu_state%S_COUNT;
            if(st==S_PIXELS&&!d.stat_advance)st=d.stat_write_stall?S_PIXELS_STALL_WRITE:S_PIXELS_DRAIN;
            ++state_clocks[st];}
        if(d.stat_burst_start){if(d.stat_burst_write)++burst_writes;else if(d.stat_burst_region)++burst_dest_reads;else{++burst_reads;if(!d.stat_pipe_fill)++fill_fsm;else if(d.stat_fill_b){++fill_b;if(d.stat_burst_line==last_b+1)++seq_b;last_b=d.stat_burst_line;}else{++fill_a;if(d.stat_burst_line==last_a+1)++seq_a;last_a=d.stat_burst_line;}}}
        finish();++clock;
    }
    void power_up(){
        d.peer_valid=0;d.reg_valid=0;d.gpu_vblank=0;d.bench_snoop_valid=0;d.reset=1;for(unsigned i=0;i<4;i++){memory.prepare(d);finish();}d.reset=0;
        for(unsigned n=0;n<400000&&!d.memory_initialized;n++){memory.prepare(d);finish();}
        check(d.memory_initialized,"fabric power-up timeout");
    }
    void reg(unsigned a,uint32_t v,unsigned strobe){
        d.reg_address=a;d.reg_write=1;d.reg_data=v;d.reg_strobe=strobe;d.reg_valid=1;
        for(unsigned n=0;;n++){const bool done=d.reg_valid&&d.reg_ready;step();if(done)break;check(n<1000000,"GPU MMIO timeout");}
        d.reg_valid=0;
    }
    void stage(const GpuMemory&m,uint32_t base){for(uint32_t a=0;a<m.bytes.size();a+=2)s.words[model_index(base+a)]=uint16_t(m.bytes[a]|(m.bytes[a+1]<<8));}
    void readback(uint32_t base,GpuMemory&m){for(uint32_t a=0;a<m.bytes.size();a+=2){uint16_t w=s.words[model_index(base+a)];m.bytes[a]=w;m.bytes[a+1]=w>>8;}}
    // A CPU/DMA write into texture RAM, reported to the GPU caches as the board's backend snoop does.
    void snoop(uint32_t offset){d.bench_snoop_valid=1;d.bench_snoop_line=(offset>>5)&0x3ffff;step();d.bench_snoop_valid=0;}
    void snoop_range(uint32_t offset,uint32_t bytes){for(uint32_t a=offset&~31u;a<offset+bytes;a+=32)snoop(a);}
    void poke(uint32_t base,uint32_t offset,uint8_t value){
        uint16_t& w=s.words[model_index(base+(offset&~1u))];
        w=(offset&1)?uint16_t((w&0x00ff)|(value<<8)):uint16_t((w&0xff00)|value);
    }
};
static void load(const std::string&path,GpuMemory&m){std::ifstream f(path,std::ios::binary);f.read(reinterpret_cast<char*>(m.bytes.data()),m.bytes.size());check(f.gcount()==int64_t(m.bytes.size()),"complete native memory image");}
static void compare(Bench&b,const GpuMemory&expected,const GpuMemory&texture_expected,const char*what){
    // The engine posts its last framebuffer line burst and goes idle; let the backend retire it.
    for(unsigned n=0;n<256;n++)b.step();
    GpuMemory got_frame,got_texture;b.readback(FRAME_BASE,got_frame);b.readback(TEXTURE_BASE,got_texture);
    if(got_frame.bytes!=expected.bytes){
        size_t diffs=0,first=0;for(size_t i=0;i<expected.bytes.size();i++)if(got_frame.bytes[i]!=expected.bytes[i]){if(!diffs)first=i;++diffs;}
        std::fprintf(stderr,"%s: frame RAM diffs=%zu first=%06zx got=%02x expected=%02x\n",what,diffs,first,got_frame.bytes[first],expected.bytes[first]);
        throw std::runtime_error("frame RAM differs from the MAME draw");
    }
    check(got_texture.bytes==texture_expected.bytes,"texture/queue RAM differs (renderer wrote it or CPU writes lost)");
}

// Part 1: the staged native first-draw packet.
static void first_draw(int peer_mode){
    Bench b;b.peer_mode=peer_mode;b.power_up();
    std::ifstream fixture("sim/obj_dir/gpu_game/fixture.txt");std::string texture_path,frame_path;
    std::getline(fixture,texture_path);std::getline(fixture,frame_path);
    unsigned capture_frame,first,end,control,display,bank1;fixture>>capture_frame>>first>>end>>control>>display>>bank1;
    check(bool(fixture)&&first==0&&end==1&&display==0,"staged fixture contract");
    GpuMemory texture,frame;load(texture_path,texture);load(frame_path,frame);
    b.stage(texture,TEXTURE_BASE);b.stage(frame,FRAME_BASE);
    GpuMemory oracle_texture=texture,expected=frame;expected.record_writes=true;vr0video_device oracle(oracle_texture,expected);
    check(oracle.process_packet(first*32)==0,"first submission has no flip");
    b.reg(0x90,bank1,3);b.reg(0x8c,control,1);
    check(b.d.gpu_draw_address==0&&b.d.gpu_display_address==0,"initial native destinations");
    const uint64_t start=b.clock;b.reg(0x80,end,3);
    uint64_t render_clocks=0;
    for(;;){b.step();check(b.clock-start<12000000,"real game packet did not finish");if(!b.d.gpu_busy&&b.d.gpu_queue_rear==end){render_clocks=b.clock-start;break;}}
    while(b.frames<2)b.step();
    check(b.d.gpu_packets==1&&b.d.gpu_pixels>=expected.writes.size(),"packet/pixel accounting");
    compare(b,expected,oracle_texture,"first draw");
    std::cout<<"PASS first draw through fabric: "<<expected.writes.size()<<" MAME pixel stores in "<<render_clocks<<" clocks, frame RAM == MAME, display frames="<<b.frames
        <<" no underrun, peer="<<b.responses<<" max latency="<<b.max_latency<<"\n";
}

// Part 2: whole real MAME frames. The oracle mirrors MAME pipeline_cb()/execute_flipping().
struct Oracle {
    GpuMemory texture,frame;vr0video_device gpu{texture,frame};
    unsigned front=0,rear=0,flip_count=0,control=0,bank1=0;bool flip_sync=false,display_bank=false;
    uint64_t area=0,quads=0,packets=0;std::map<std::string,uint64_t> categories;
    uint32_t stat_pal=0,stat_trans=0,last_pal=~0u;uint64_t pal_loads=0,pal_hits=0;std::vector<uint64_t> pal_lru;
    void palette_write(uint32_t offset){for(size_t i=0;i<pal_lru.size();)if(uint32_t(pal_lru[i]>>24)==(offset>>10))pal_lru.erase(pal_lru.begin()+i);else ++i;}
    uint32_t b1()const{return (bank1&0x8000)?0x400000:0x100000;}
    void drain(){
        while((control&4)&&!flip_sync&&rear!=front){
            const uint32_t p=rear*64;const uint16_t flags=texture.read_word(p);
            if((flags&0x100)&&!(flags&0x81)){
                const int dx=texture.read_word(p+2)&0x3ff,dy=texture.read_word(p+4)&0x1ff,ex=texture.read_word(p+6)&0x3ff,ey=texture.read_word(p+8)&0x1ff;
                if(ex>=dx&&ey>=dy){
                    const uint64_t a=uint64_t(ex-dx+1)*uint64_t(ey-dy+1);area+=a;++quads;
                    // Category: texture/tiled/format/alpha/shade/clamp (format/tiling from the packet if present).
                    char key[64];const uint16_t w28=texture.read_word(p+56);
                    std::snprintf(key,sizeof key,"%s%s fmt%d%s%s%s",(flags&8)?"tex":"fill",(flags&8)&&(w28&0x1000)?" tiled":"",(w28>>6)&3,
                        (flags&2)?" alpha":"",(flags&0x10)?" shade":"",(flags&0x20)?" clamp":"");
                    categories[std::string(key)+((flags&0x4000)?"":" (fmt from prior)")]+=a;
                }
            }
            // Palette-load statistics (analysis only): MAME reloads when the offset differs from
            // the last load; count loads and how many an N-entry (offset, transparent colour)
            // palette cache, invalidated by CPU writes into the palette, would have served.
            if(flags&0x81)last_pal=~0u;
            else{
                if(flags&0x2000)stat_trans=texture.read_word(p+46)|(uint32_t(texture.read_word(p+48)&0xff)<<16);
                if(flags&0x4000)stat_pal=texture.read_word(p+54)>>3;
                if((flags&0x40)&&stat_pal!=last_pal){
                    ++pal_loads;last_pal=stat_pal;const uint64_t key=(uint64_t(stat_pal)<<24)|stat_trans;
                    bool hit=false;for(size_t i=0;i<pal_lru.size();i++)if(pal_lru[i]==key){hit=true;pal_lru.erase(pal_lru.begin()+i);break;}
                    if(hit)++pal_hits;pal_lru.insert(pal_lru.begin(),key);if(pal_lru.size()>8)pal_lru.pop_back();
                }
            }
            const int flip=gpu.process_packet(rear*32);rear=(rear+1)&0x7ff;++packets;
            if(flip&1)flip_sync=true;
            if(flip&0x80){const uint32_t f=display_bank?b1():0,bk=display_bank?0:b1();gpu.m_draw_dest=(control&0x80)?bk:f;}
        }
    }
    // The RTL flips only with a pending flip count (MAME master, commit 81f0186); same here.
    void vblank(){
        if(!(control&4)||!flip_sync||!flip_count)return;
        const uint32_t f=display_bank?b1():0,bk=display_bank?0:b1();
        gpu.m_draw_dest=(control&0x80)?f:bk;gpu.m_display_dest=f;flip_sync=false;--flip_count;display_bank=!display_bank;
    }
    void write_reg(uint32_t offset,uint32_t data,uint32_t mask){
        if(offset==0x80&&(mask&0xffff))front=((front&~mask)|(data&mask))&0x7ff;
        if(offset==0x8c&&(mask&0xff)){control=data&0x8f;if(data&8){front=0;rear=0;}}
        if(offset==0x90&&(mask&0xffff))bank1=data&0xffff;
        if(offset==0xa4&&(mask&0xff0000)){const unsigned fc=(data>>16)&0xff;if(fc==1)++flip_count;else if(fc==0)flip_count=0;}
    }
};
struct FrameResult{unsigned frame;uint64_t busy,area,quads,packets,pixels;};
static std::vector<FrameResult> replay_window(const std::string&dir,int peer_mode,uint64_t&worst_busy){
    std::ifstream st(dir+"/state.txt");unsigned start,end,rear,front,control,display_bank,bank1,flip_count;
    st>>start>>end>>rear>>front>>control>>display_bank>>bank1>>flip_count;check(bool(st),"frame capture state");
    Bench b;b.peer_mode=peer_mode;b.power_up();
    Oracle o;load(dir+"/texture.bin",o.texture);load(dir+"/frame.bin",o.frame);
    b.stage(o.texture,TEXTURE_BASE);b.stage(o.frame,FRAME_BASE);
    // Settle: wait until the engine is idle or blocked by a sync flip, oracle drains likewise.
    auto settle=[&](){o.drain();for(uint64_t n=0;b.d.gpu_busy||(b.d.gpu_queue_rear!=o.rear&&!b.d.gpu_flip_sync);n++){b.step();check(n<60000000,"GPU did not finish the submitted queue");}
        check(b.d.gpu_queue_rear==o.rear&&b.d.gpu_queue_front==o.front&&bool(b.d.gpu_flip_sync)==o.flip_sync,"RTL queue/flip state differs from the MAME pipeline");};
    // Reproduce MAME's queue position: run zeroed (no-draw) packets up to the captured rear in
    // both models, then restore the captured slots. Both engines start from reset render state.
    b.reg(0x90,bank1,3);o.write_reg(0x90,bank1,0xffff);
    b.reg(0x8c,control&0x87,1);o.write_reg(0x8c,control&0x87,0xff);
    b.phase="queue-position";
    if(rear){
        std::vector<uint8_t> saved(o.texture.bytes.begin(),o.texture.bytes.begin()+rear*64);
        std::fill(o.texture.bytes.begin(),o.texture.bytes.begin()+rear*64,0);
        for(uint32_t a=0;a<rear*64u;a++)b.poke(TEXTURE_BASE,a,0);
        b.snoop_range(0,rear*64u);
        b.reg(0x80,rear,3);o.write_reg(0x80,rear,0xffff);settle();
        std::copy(saved.begin(),saved.end(),o.texture.bytes.begin());
        for(uint32_t a=0;a<rear*64u;a++)b.poke(TEXTURE_BASE,a,saved[a]);
        b.snoop_range(0,rear*64u);
        o.area=o.quads=o.packets=0;
    }
    for(unsigned i=0;i<flip_count;i++){b.reg(0xa4,0x10000,4);o.write_reg(0xa4,0x10000,0xff0000);}
    const uint64_t pixels0=b.d.gpu_pixels;
    b.busy=0;b.state_clocks.fill(0);b.burst_reads=b.burst_writes=b.burst_dest_reads=b.fill_fsm=b.fill_a=b.fill_b=0;
    b.be_write=b.be_dest=b.be_fill=b.be_word=b.be_activates=b.be_columns=0;const uint64_t clock0=b.clock;
    b.phase="replay";
    b.reg(0x80,front,3);o.write_reg(0x80,front,0xffff);
    std::ifstream ev(dir+"/events.txt");std::string line;
    std::vector<FrameResult> results;unsigned frame=start;uint64_t busy0=0,area0=0,quads0=0,packets0=0,pix0=pixels0;
    uint64_t events=0;
    while(std::getline(ev,line)){
        if(line.empty())continue;
        ++events;
        if(line[0]=='V'){
            settle();
            results.push_back({frame,b.busy-busy0,o.area-area0,o.quads-quads0,o.packets-packets0,uint64_t(b.d.gpu_pixels)-pix0});
            busy0=b.busy;area0=o.area;quads0=o.quads;packets0=o.packets;pix0=b.d.gpu_pixels;++frame;
            // The flip changes the scanned bank: deliver it in the raster's vertical blank,
            // as the board does (a mid-frame bank change is a display underrun).
            while(!b.d.vblank)b.step();
            o.vblank();b.d.gpu_vblank=1;b.step();b.d.gpu_vblank=0;
            continue;
        }
        char kind;uint32_t address,data,mask;std::istringstream in(line);in>>kind>>std::hex>>address>>data>>mask;check(bool(in),"frame capture event");
        if(kind=='R'){
            const uint32_t offset=address&0xfffc;
            settle();
            unsigned strobe=0;for(unsigned i=0;i<4;i++)if((mask>>(8*i))&0xff)strobe|=1u<<i;
            if(offset>=0x80&&offset<0xa8){b.reg(offset,data,strobe);o.write_reg(offset,data,mask);}
        }else{
            // CPU/DMA RAM write: applied while the engine is idle (the oracle renders each packet
            // when it is submitted, against the RAM as written up to that point).
            settle();
            const bool tex=address<0x04000000;GpuMemory&m=tex?o.texture:o.frame;const uint32_t base=tex?TEXTURE_BASE:FRAME_BASE;
            const uint32_t offset=(address&0x7ffffc);
            for(unsigned i=0;i<4;i++)if((mask>>(8*i))&0xff){m.bytes[offset+i]=uint8_t(data>>(8*i));b.poke(base,offset+i,uint8_t(data>>(8*i)));}
            if(tex){b.snoop(offset);o.palette_write(offset);}
        }
    }
    settle();
    compare(b,o.frame,o.texture,dir.c_str());
    for(const auto&r:results){
        if(r.busy>worst_busy)worst_busy=r.busy;
        std::printf("FRAME %u: GPU busy %llu clocks = %.1f%% of 60 Hz budget; %llu packets, %llu quads, area %llu px (%.2f clk/px), %llu stores\n",
            r.frame,(unsigned long long)r.busy,100.0*r.busy/FRAME_BUDGET,(unsigned long long)r.packets,(unsigned long long)r.quads,(unsigned long long)r.area,
            r.area?double(r.busy)/r.area:0.0,(unsigned long long)r.pixels);
    }
    std::printf("WINDOW %u-%u: %llu events, frame RAM == MAME, peer=%llu max latency=%llu, SDRAM reads/writes/refresh=%llu/%llu/%llu; GPU bursts read=%llu dest-read=%llu write=%llu\n",
        start,end,(unsigned long long)events,(unsigned long long)b.responses,(unsigned long long)b.max_latency,
        (unsigned long long)b.s.reads,(unsigned long long)b.s.writes,(unsigned long long)b.s.refreshes,
        (unsigned long long)b.burst_reads,(unsigned long long)b.burst_dest_reads,(unsigned long long)b.burst_writes);
    // Deadline margin: a line fetch launches one line period before it is displayed. Require
    // the worst fetch under GPU + CPU load to use at most 60% of the 5460-clock line period,
    // so slower hardware pin timing and real CPU/DMA/sound traffic cannot push it over.
    std::printf("  display line fetch: %llu lines, mean %.0f, max %llu clocks = %.1f%% of the 5460-clock line period\n",(unsigned long long)b.lines,b.lines?double(b.line_total)/b.lines:0.0,(unsigned long long)b.line_max,100.0*b.line_max/5460.0);
    check(b.line_max<=5460*6/10,"display line fetch exceeds 60% of the line period under load");
    std::printf("  palette loads=%llu, of which an 8-entry coherent palette cache would serve %llu\n",(unsigned long long)o.pal_loads,(unsigned long long)o.pal_hits);
    std::printf("  quad area by kind:");for(const auto&c:o.categories)std::printf(" [%s]=%llu",c.first.c_str(),(unsigned long long)c.second);std::printf("\n");
    std::printf("  texture fills: packet/palette=%llu pipeline A=%llu (sequential %llu) B=%llu (sequential %llu)\n",(unsigned long long)b.fill_fsm,(unsigned long long)b.fill_a,(unsigned long long)b.seq_a,(unsigned long long)b.fill_b,(unsigned long long)b.seq_b);
    {const double span=double(b.clock-clock0);
     std::printf("  SDRAM backend occupancy over %.0f clocks: GPU write bursts %.1f%%, dest reads %.1f%%, texture fills %.1f%%, word path (scanout/CPU) %.1f%%, idle %.1f%%; %llu activates, %llu column commands\n",
        span,100*b.be_write/span,100*b.be_dest/span,100*b.be_fill/span,100*b.be_word/span,100*(span-b.be_write-b.be_dest-b.be_fill-b.be_word)/span,
        (unsigned long long)b.be_activates,(unsigned long long)b.be_columns);}
    std::printf("  dest prefetch: issued=%llu used=%llu\n",(unsigned long long)b.pf_acc,(unsigned long long)b.pf_used);
    std::printf("  busy clocks by state:");
    for(unsigned i=0;i<S_STAT_COUNT;i++)if(b.state_clocks[i])std::printf(" %s=%.1f%%",stat_names[i],100.0*b.state_clocks[i]/std::max<uint64_t>(1,b.busy));
    std::printf("\n");
    return results;
}

int main(int argc,char**argv){Verilated::commandArgs(argc,argv);try{
    // Default: every capture under the saturating peer (stress), then under the sparse peer.
    std::vector<int> modes={1,2};std::string only;
    for(int i=1;i<argc;i++){std::string a=argv[i];
        if(a=="quiet")modes={0};else if(a=="peer=saturating")modes={1};else if(a=="peer=sparse")modes={2};
        else if(a.rfind("window=",0)==0)only=a.substr(7);}
    static const char* mode_names[3]={"no peer","saturating CPU peer","sparse CPU peer"};
    std::vector<std::string> summary;
    for(int mode:modes){
        std::printf("=== %s ===\n",mode_names[mode]);
        if(only.empty())first_draw(mode);
        std::ifstream list("sim/obj_dir/gpu_fabric/frames.txt");std::string dir;uint64_t worst=0;unsigned windows=0,frames=0;
        while(std::getline(list,dir)){
            if(dir.empty()||(!only.empty()&&dir.find(only)==std::string::npos))continue;
            frames+=replay_window(dir,mode,worst).size();++windows;
        }
        check(windows>0,"no whole-frame MAME captures staged");
        char line[256];std::snprintf(line,sizeof line,"%s: %u windows / %u frames, worst frame GPU busy %llu clocks = %.1f%% of the 60 Hz budget",
            mode_names[mode],windows,frames,(unsigned long long)worst,100.0*worst/FRAME_BUDGET);
        summary.push_back(line);
    }
    std::printf("PASS GPU through fabric: real MAME frames, frame RAM == MAME, no display underrun");
    for(const auto&s:summary)std::printf("; %s",s.c_str());
    std::printf("\n");
    return 0;
}catch(const std::exception&e){std::cerr<<"FAIL GPU through fabric: "<<e.what()<<"\n";return 1;}}
