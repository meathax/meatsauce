// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vn8080_board.h"
#include "verilated.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>
#include <array>
#include <iomanip>
#include <cstdlib>
namespace fs=std::filesystem;
struct Input { unsigned frame,p0,p1,p2,dip; };
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    if(argc<4) { std::cerr<<"usage: board packed.bin output-dir frames [inputs.csv]\n"; return 2; }
    Vn8080_board b;
    fs::path out=argv[2]; fs::create_directories(out);
    unsigned frame_limit=std::stoul(argv[3]);
    const bool startup_check=argc>5&&std::string(argv[5])=="--startup-check";
    const bool no_snapshots=argc>5&&std::string(argv[5])=="--no-snapshots";
    const unsigned bus_frame=std::getenv("SHERIFF_BUS_FRAME")?std::stoul(std::getenv("SHERIFF_BUS_FRAME")):57;
    std::vector<unsigned> bus_frames{bus_frame};
    if(const char* windows=std::getenv("SHERIFF_BUS_FRAMES")) {
        bus_frames.clear();std::istringstream stream(windows);std::string token;
        while(std::getline(stream,token,','))bus_frames.push_back(std::stoul(token));
    }
    std::vector<Input> inputs;
    if(argc>4) {std::ifstream f(argv[4]);std::string line;while(std::getline(f,line)) {
        if(line.empty()||!isdigit(line[0]))continue;
        for(auto&c:line)if(c==',')c=' ';
        Input a;std::istringstream s(line);s>>a.frame>>a.p0>>a.p1>>a.p2>>a.dip;
        inputs.push_back(a);
    }}
    b.reset=1;b.pause=0;b.flip_screen=0;b.debug_req=0;b.debug_freeze=0;b.debug_wr=0;b.debug_addr=0;b.debug_dout=0;
    b.input0=0;b.input1=0;b.input2=0;b.input3=0xfc;
    auto step=[&]() {b.clk=0;b.eval();b.clk=1;b.eval();};
    std::ifstream rom(argv[1],std::ios::binary);
    if(!rom){std::cerr<<"missing ROM image\n";return 2;}
    std::vector<uint8_t> image((std::istreambuf_iterator<char>(rom)),{});
    if(image.size()!=0x4800){std::cerr<<"ROM image must be 0x4800 bytes\n";return 2;}
    for(size_t a=0;a<image.size();a++) {b.load_wr=1;b.load_addr=a;b.load_data=image[a];step();}
    b.load_wr=0;for(int t=0;t<1000;t++)step();b.reset=0;
    // Observational sidecar: no extra eval/step, and no divider phase port exists.
    std::ofstream epochs(out/"capture_epochs.csv");
    epochs<<"event,tick,sample_site,excluded_reset_clocks,h,v,sync,dbin,address,status,divider_phase,reset_edge_observed\n";
    auto epoch=[&](const char* event,uint64_t tick,const char* site) {
        epochs<<event<<','<<tick<<','<<site<<','<<(image.size()+1000)<<','
              <<b.pixel_x<<','<<unsigned(b.pixel_y)<<','<<unsigned(b.cpu_sync)<<','
              <<unsigned(b.cpu_dbin)<<','<<b.cpu_address<<','<<unsigned(b.cpu_status)
              <<",unexposed,"<<(std::string(event)=="external_reset_release"?"true":"false")<<'\n';
        epochs.flush();
    };
    epoch("external_reset_release",0,"after_reset_assignment_before_eval");
    bool epoch_sync=false,epoch_dbin=false;
    if(argc>5 && std::string(argv[5])=="--pause-check") {
        for(unsigned t=0;t<2000;t++)step();
        b.pause=1;for(unsigned t=0;t<20;t++)step();
        const unsigned cpu_address=b.cpu_address, sound_pc=b.sound_pc, sound_port=b.sound_p2;
        unsigned pixels=0;
        for(unsigned t=0;t<819200;t++) {
            step();pixels+=b.ce_pixel;
            if(b.cpu_address!=cpu_address || b.sound_pc!=sound_pc || b.sound_p2!=sound_port || b.cpu_write) {
                std::cerr<<"FAIL CPU/sound activity during pause\n";return 1;
            }
        }
        if(pixels!=81920){std::cerr<<"FAIL paused raster cadence "<<pixels<<'\n';return 1;}
        // Safe score-service read/write borrows the halted CPU RAM port while
        // video continues. Restore the untouched byte before resuming the game.
        b.debug_req=1;b.debug_addr=0x3f00;step();unsigned original=b.debug_data;
        b.debug_wr=1;b.debug_dout=0x5a;step();b.debug_wr=0;step();
        if(b.debug_data!=0x5a){std::cerr<<"FAIL paused score service write/read\n";return 1;}
        b.debug_wr=1;b.debug_dout=original;step();b.debug_wr=0;
        b.debug_freeze=1;step();unsigned x=b.pixel_x,y=b.pixel_y;
        for(unsigned t=0;t<4096;t++){step();if(b.ce_pixel||b.pixel_x!=x||b.pixel_y!=y){std::cerr<<"FAIL checkpoint freeze\n";return 1;}}
        std::cout<<"PASS: paused CPU/MCU/DAC, 81920 raster pixels per frame, safe score RAM service and frozen debug checkpoint\n";
        return 0;
    }
    std::ofstream trace(out/"io.csv"), bus(out/"bus.csv"), memory_trace(out/"memory_writes.bin",std::ios::binary);
    std::ofstream audio_trace(out/"audio.raw",std::ios::binary), sound_trace(out/"sound.csv");
    sound_trace<<"tick,pc,p1,p2,dac\n";
    unsigned previous_p1=256,previous_p2=256;
    trace<<"tick,frame,y,x,kind,address,data,status,inte\n";
    bus<<"tick,kind,address,data,status\n";
    std::array<uint8_t,256*256*3> pixels{};
    unsigned frames=0;size_t input_index=0;uint64_t writes=0,acks=0;
    const uint64_t maximum=uint64_t(frame_limit+1)*819200;
    std::ofstream startup(out/"cpu_startup.csv");
    startup<<"tick,sync,dbin,wr_n,inte,address,status,h,v\n";
    uint64_t first_sync=~0ULL,first_opcode=~0ULL;
    for(uint64_t tick=0;tick<maximum && (startup_check?tick<160:frames<frame_limit);tick++) {
        while(input_index<inputs.size()&&inputs[input_index].frame<=frames) {
            const auto&a=inputs[input_index++];b.input0=a.p0;b.input1=a.p1;b.input2=a.p2;b.input3=a.dip;
        }
        b.clk=0;b.eval();
        if(tick<160)startup<<tick<<','<<unsigned(b.cpu_sync)<<','<<unsigned(b.cpu_dbin)<<','<<unsigned(b.cpu_wr_n)<<','<<unsigned(b.cpu_inte)<<','<<b.cpu_address<<','<<unsigned(b.cpu_status)<<','<<b.pixel_x<<','<<unsigned(b.pixel_y)<<'\n';
        if(b.cpu_sync&&!epoch_sync){epoch("first_observed_sync",tick,"clk_low_eval_before_rising_edge");epoch_sync=true;}
        if(b.cpu_dbin&&!epoch_dbin){epoch("first_observed_dbin",tick,"clk_low_eval_before_rising_edge");epoch_dbin=true;}
        if(b.cpu_sync&&first_sync==~0ULL)first_sync=tick;
        if(b.cpu_read&&(b.cpu_status&0x20)&&b.cpu_address==0&&first_opcode==~0ULL)first_opcode=tick;
        const uint64_t capture_tick=tick;
        if(b.cpu_write||b.cpu_read||b.cpu_ack) {
                bool bus_window=tick<200000;
                for(unsigned start:bus_frames)bus_window|=frames>=start && frames<=start+1;
                if(bus_window) bus<<capture_tick<<","<<(b.cpu_ack?"ack":b.cpu_write?"write":"read")<<","<<b.cpu_address<<","<<unsigned(b.cpu_write?b.cpu_dout:b.cpu_din)<<","<<unsigned(b.cpu_status)<<"\n";
            if(b.cpu_write) {
                ++writes;
                if(!(b.cpu_status&0x10) && (b.cpu_address&0x4000)) {
                    uint16_t a=b.cpu_address&0x7fff;uint8_t d=b.cpu_dout;
                    memory_trace.write((char*)&capture_tick,8);memory_trace.write((char*)&a,2);memory_trace.write((char*)&d,1);
                }
            }
            if(b.cpu_ack)++acks;
            if((b.cpu_status&0x50)||b.cpu_ack)
                    trace<<capture_tick<<","<<frames<<","<<unsigned(b.pixel_y)<<","<<b.pixel_x<<","<<(b.cpu_ack?"ack":b.cpu_write?"out":"in")<<","<<b.cpu_address<<","<<unsigned(b.cpu_write?b.cpu_dout:b.cpu_din)<<","<<unsigned(b.cpu_status)<<","<<unsigned(b.cpu_inte)<<"\n";
        }
        b.clk=1;b.eval();
        if(b.audio_ce) {int16_t sample=b.audio;audio_trace.write((char*)&sample,2);}
        // P2 low nibble is multiplexed external ROM address, not sound data.
        // Record the sound-relevant changes without logging every ROM fetch.
        if(b.sound_p1!=previous_p1 || ((b.sound_p2^previous_p2)&0xf0)) {
            sound_trace<<tick<<','<<b.sound_pc<<','<<unsigned(b.sound_p1)<<','<<unsigned(b.sound_p2)<<','<<unsigned(b.sound_dac)<<'\n';
            previous_p1=b.sound_p1;previous_p2=b.sound_p2;
        }
        if(b.ce_pixel && b.pixel_x<256) {
            auto p=(b.pixel_y*256+b.pixel_x)*3;
            pixels[p]=(b.rgb&1)?255:0;pixels[p+1]=(b.rgb&2)?255:0;pixels[p+2]=(b.rgb&4)?255:0;
        }
        if(b.ce_pixel && b.pixel_x==0 && b.pixel_y==240 && tick>819000) {
            ++frames;
            if(frames<=4||frames%60==0||frames==frame_limit) {
                std::ostringstream stem;stem<<"frame_"<<std::setw(5)<<std::setfill('0')<<frames;
                std::ofstream ppm(out/(stem.str()+".ppm"),std::ios::binary);
                ppm<<"P6\n256 224\n255\n";ppm.write((char*)pixels.data()+16*256*3,256*224*3);
                if(!no_snapshots){
                    b.pause=1;b.debug_req=1;b.debug_freeze=1;
                    std::ofstream ram(out/(stem.str()+".ram"),std::ios::binary);
                    for(unsigned a=0;a<16384;a++) {b.debug_addr=a;step();ram.put(char(b.debug_data));}
                    // Return the RAM port while execution and emulated time
                    // remain frozen, then release the observation pause.
                    b.debug_req=0;step();step();b.debug_freeze=0;b.pause=0;
                }
                std::ofstream state(out/(stem.str()+".state"));
                state<<"tick="<<tick<<" address="<<b.cpu_address<<" mode="<<unsigned(b.color_mode)<<" color="<<unsigned(b.color_data)<<" flip="<<unsigned(b.flip)<<" shift="<<b.shift_data<<" count="<<unsigned(b.shift_count)<<" inte="<<unsigned(b.cpu_inte)<<" irq="<<unsigned(b.irq)<<"\n";
            }
        }
    }
    std::cout<<"frames="<<frames<<" writes="<<writes<<" IRQ acknowledges="<<acks<<" address="<<std::hex<<b.cpu_address<<"\n";
    if(startup_check){
        std::cout<<std::dec<<"Startup SYNC="<<first_sync<<" opcode DBIN="<<first_opcode<<" inferred T1 phi1="<<(first_sync-13)<<" master ticks after pin-reset release\n";
        return first_sync!=~0ULL&&first_opcode-first_sync==25?0:1;
    }
    return frames==frame_limit && writes && acks ? 0:1;
}
