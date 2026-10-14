// SPDX-License-Identifier: GPL-3.0-or-later
// Host diagnostics only. Observe natural RTL execution; never restore/inject state.
#pragma once
#include <algorithm>
#include <array>
#include <filesystem>
#include <cstdio>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <map>
#include <string>
#include <vector>
#include "frame_capture.hpp"
#include "scanout_source.hpp"

struct BootObserver {
    Vcs_boot_probe& d;
    Memory& memory;
    unsigned& instructions;
    unsigned& requests;
    unsigned& mmios;
    std::array<uint64_t,5>& clients;
    uint64_t& cp_transfers;
    uint64_t& sound_mmios;
    uint64_t& audio_samples;
    uint64_t& audio_nonzero;
    std::ofstream progress;
    std::ofstream gpu_bus,video_mmio,concurrent_writes,sound_mmio;
    struct BusEvent {uint64_t at,start;unsigned client,target,strobe;uint32_t address,data;bool write,response,error;};
    std::array<BusEvent,128> bus_tail{};
    uint64_t bus_tail_count=0;
    BusEvent pending_bus{};bool diagnostic_pending=false;
    void bus_event(BusEvent e){bus_tail[bus_tail_count++%bus_tail.size()]=e;}
    void bus_accept(unsigned client,unsigned target,uint32_t address,uint32_t data,unsigned strobe,bool write){
        pending_bus={clock,clock,client,target,strobe,address,data,write,false,false};diagnostic_pending=true;bus_event(pending_bus);
    }
    void bus_reply(uint32_t data,bool error){if(!diagnostic_pending)return;diagnostic_pending=false;auto e=pending_bus;e.at=clock;e.data=data;e.response=true;e.error=error;bus_event(e);}
    void sound_access(uint32_t address,uint32_t data,unsigned strobe,bool write,bool error){
        sound_mmio<<clock<<','<<std::hex<<address<<','<<data<<','<<strobe<<std::dec<<','<<write<<','<<error<<'\n';
    }
    void audio_failure(){
        reason="audio_failure";row();
        std::ofstream f(ROOT+"/audio_failure_bus.csv",std::ios::trunc);
        f<<"clock,start,latency,client,target,address,data,strobe,write,response,error\n";
        for(uint64_t i=bus_tail_count>bus_tail.size()?bus_tail_count-bus_tail.size():0;i<bus_tail_count;++i){
            const auto&e=bus_tail[i%bus_tail.size()];f<<e.at<<','<<e.start<<','<<e.at-e.start<<','<<e.client<<','<<e.target<<','
                <<std::hex<<e.address<<','<<e.data<<','<<e.strobe<<std::dec<<','<<e.write<<','<<e.response<<','<<e.error<<'\n';
        }
        if(!f)throw std::runtime_error("audio failure bus trace write failed");
    }
    std::map<uint32_t,uint64_t> pages;
    std::array<uint64_t,64> access_latencies{};
    std::vector<uint8_t> rgb=std::vector<uint8_t>(1024*1024*3,0);
    CompleteFrameCapture frames;
    ScanoutPixelSource pixel_source;
    uint64_t clock=0,start_access=0,accesses=0,access_cycles=0;
    uint64_t enabled_accesses=0,enabled_cycles=0,disabled_accesses=0,disabled_cycles=0;
    uint64_t raster_frames=0,active_pixels=0,irq_acks=0;
    uint32_t min_x=1024,min_y=1024,max_x=0,max_y=0;
    bool access_enabled=false,previous_vblank=false,first_gpu_saved=false,clipped=false;
    bool active_packet_completed=false;
    bool gpu_start_saved=false;
    bool context_trace_closed=false;
    uint64_t gpu_trace_requests=0,video_trace_writes=0,concurrent_trace_writes=0;
    uint64_t cabinet_commands=0,cabinet_releases=0,cabinet_sequence=0;
    uint32_t previous_packets=0;
    uint64_t report_period=50000000;
    std::string reason="running";
    static constexpr const char* BASE="sim/obj_dir/boot_probe/activity";
    const std::string run_id=std::to_string(std::chrono::system_clock::now().time_since_epoch().count());
    const std::string ROOT=std::string(BASE)+"/"+run_id;

    BootObserver(Vcs_boot_probe& dut,Memory& ram,unsigned& ins,unsigned& req,unsigned& io,
                 std::array<uint64_t,5>& owners,uint64_t& cp,uint64_t& sound,
                 uint64_t& samples,uint64_t& nonzero):
        d(dut),memory(ram),instructions(ins),requests(req),mmios(io),clients(owners),
        cp_transfers(cp),sound_mmios(sound),audio_samples(samples),audio_nonzero(nonzero) {
        std::filesystem::create_directories(ROOT);
        std::ofstream pointer(std::string(BASE)+"/latest_run.json",std::ios::trunc);
        pointer << "{\"schema\":1,\"run_id\":\"" << run_id << "\",\"directory\":\"" << ROOT << "\"}\n";
        if(!pointer)throw std::runtime_error("private boot run identity write failed");
        sound_mmio.open(ROOT+"/sound_mmio.csv",std::ios::trunc);
        if(!sound_mmio)throw std::runtime_error("private sound MMIO log open failed");
        sound_mmio<<"clock,address,data,strobe,write,error\n";
        progress.open(std::string(ROOT)+"/progress.csv",std::ios::trunc);
        if(!progress)throw std::runtime_error("cannot open private boot activity log");
        gpu_bus.open(ROOT+"/gpu_bus.csv",std::ios::trunc);
        video_mmio.open(ROOT+"/video_mmio.csv",std::ios::trunc);
        concurrent_writes.open(ROOT+"/concurrent_graphics_writes.csv",std::ios::trunc);
        if(!gpu_bus || !video_mmio || !concurrent_writes)throw std::runtime_error("private GPU context log open failed");
        gpu_bus << "clock,address,value,strobe,write,error\n";
        video_mmio << "clock,address,data,strobe,error\n";
        concurrent_writes << "clock,client,address,data,strobe,error\n";
        progress << "clock,instructions,pc,sr,sp,er,cache_enabled,cache_hits,cache_misses,cache_invalidations,"
                    "cp_transfers,memory_requests,mmio,cpu_memory,dma_memory,gpu_memory,spu_memory,scanout_memory,"
                    "sound_mmio,audio_samples,audio_nonzero,gpu_packets,gpu_pixels,scanout_words,raster_frames,active_pixels,irq_acks,"
                    "architectural_accesses,access_cycles,enabled_accesses,enabled_cycles,disabled_accesses,disabled_cycles\n";
        row();
    }
    ~BootObserver(){
        try {
            if(reason=="running")reason="diagnostic_return";
            row(); snapshot("terminal",true);
        }
        catch(const std::exception& e){std::fprintf(stderr,"FAIL boot snapshot: %s\n",e.what());}
    }
    void accepted(uint64_t at){start_access=at;access_enabled=d.cache_enabled;}
    void responded(uint64_t at){
        uint64_t latency=at-start_access;
        ++accesses;access_cycles+=latency;++access_latencies[std::min<uint64_t>(latency,63)];
        if(access_enabled){++enabled_accesses;enabled_cycles+=latency;}
        else{++disabled_accesses;disabled_cycles+=latency;}
    }
    void row(){
        progress << clock << ',' << instructions << ',' << std::hex << std::setfill('0')
                 << std::setw(8) << d.pc << ',' << std::setw(8) << d.sr << ','
                 << std::setw(8) << d.sp << ',' << std::setw(8) << d.er << std::dec
                 << ',' << unsigned(d.cache_enabled) << ',' << d.cache_hits << ',' << d.cache_misses
                 << ',' << d.cache_invalidations << ',' << cp_transfers << ',' << requests << ',' << mmios;
        for(auto n:clients)progress << ',' << n;
        progress << ',' << sound_mmios << ',' << audio_samples << ',' << audio_nonzero
                 << ',' << d.gpu_packets << ',' << d.gpu_pixels << ',' << d.video_words
                 << ',' << raster_frames << ',' << active_pixels << ',' << irq_acks
                 << ',' << accesses << ',' << access_cycles
                 << ',' << enabled_accesses << ',' << enabled_cycles
                 << ',' << disabled_accesses << ',' << disabled_cycles << '\n';
        progress.flush();
        gpu_bus.flush();video_mmio.flush();concurrent_writes.flush();sound_mmio.flush();
        if(!progress)throw std::runtime_error("private boot activity write failed");
    }
    void gpu_begin(){
        if(!gpu_start_saved){gpu_start_saved=true;row();snapshot("first_gpu_request",true);}
    }
    void memory_access(unsigned client,unsigned target,uint32_t address,uint32_t data,
                       unsigned strobe,bool write,uint32_t read_data,bool error){
        if(context_trace_closed)return;
        if(client==2){
            ++gpu_trace_requests;
            gpu_bus << clock << ',' << std::hex << std::setfill('0') << std::setw(8) << address
                    << ',' << std::setw(8) << (write?data:read_data) << ',' << strobe << std::dec
                    << ',' << write << ',' << error << '\n';
        }else if(gpu_start_saved && write && (target==2 || target==3)){
            ++concurrent_trace_writes;
            concurrent_writes << clock << ',' << client << ',' << std::hex << std::setfill('0') << std::setw(8) << address
                              << ',' << std::setw(8) << data << ',' << strobe << std::dec << ',' << error << '\n';
        }
    }
    void video_write(uint32_t address,uint32_t data,unsigned strobe,bool error){
        if(context_trace_closed)return;
        ++video_trace_writes;
        video_mmio << clock << ',' << std::hex << std::setfill('0') << std::setw(8) << address
                   << ',' << std::setw(8) << data << ',' << strobe << std::dec << ',' << error << '\n';
    }
    void raw(const std::string& stem,const char* name,const uint8_t* bytes,size_t length){
        std::ofstream f(stem+"/"+name,std::ios::binary|std::ios::trunc);
        f.write(reinterpret_cast<const char*>(bytes),length);
        if(!f)throw std::runtime_error("private boot RAM snapshot write failed");
    }
    void snapshot(const char* name,bool memories){
        const std::string stem=std::string(ROOT)+"/"+name;
        std::filesystem::create_directories(stem);
        std::ofstream f(stem+"/state.json",std::ios::trunc);
        f << "{\n  \"schema\":1,\"run_id\":\"" << run_id << "\",\"natural_rtl_observation\":true,\"restorable_checkpoint\":false,\n"
          << "  \"clock\":" << clock << ",\"instructions\":" << instructions
          << ",\"reason\":\"" << reason << "\",\n  \"pc\":\"" << std::hex << std::setfill('0') << std::setw(8) << d.pc
          << "\",\"sr\":\"" << std::setw(8) << d.sr << "\",\"sp\":\"" << std::setw(8) << d.sp
          << "\",\"er\":\"" << std::setw(8) << d.er << "\",\n  \"registers\":[";
        for(unsigned i=0;i<8;++i)f << (i?",":"") << '"' << std::setw(8) << d.registers[i] << '"';
        f << std::dec << "],\n  \"flash_bank\":" << unsigned(d.flash_bank)
          << ",\"cache_enabled\":" << unsigned(d.cache_enabled)
          << ",\"cache_hits\":" << d.cache_hits << ",\"cache_misses\":" << d.cache_misses
          << ",\"cp_transfers\":" << cp_transfers << ",\"gpu_packets\":" << d.gpu_packets
          << ",\"gpu_pixels\":" << d.gpu_pixels << ",\"raster_frames\":" << raster_frames
          << ",\"gpu_trace_requests\":" << gpu_trace_requests << ",\"video_trace_writes\":" << video_trace_writes
          << ",\"concurrent_trace_writes\":" << concurrent_trace_writes
          << ",\"context_trace_closed\":" << (context_trace_closed?"true":"false")
          << ",\"context_trace_scope\":\"reset_through_first_draw\""
          << ",\"cabinet_commands\":" << cabinet_commands << ",\"cabinet_releases\":" << cabinet_releases
          << ",\"cabinet_sequence\":" << cabinet_sequence
          << ",\"cabinet_pins\":{\"p1_p2_n\":" << d.p1_p2_n << ",\"p3_p4_n\":" << d.p3_p4_n
          << ",\"system_n\":" << unsigned(d.system_n) << ",\"dips_n\":" << unsigned(d.dips_n) << '}'
          << ",\"active_pixels\":" << active_pixels << ",\"irq_acks\":" << irq_acks
          << ",\"audio_samples\":" << audio_samples << ",\"audio_nonzero\":" << audio_nonzero
          << ",\"architectural_accesses\":" << accesses << ",\"access_cycles\":" << access_cycles
          << ",\"enabled_accesses\":" << enabled_accesses << ",\"enabled_cycles\":" << enabled_cycles
          << ",\"disabled_accesses\":" << disabled_accesses << ",\"disabled_cycles\":" << disabled_cycles
          << ",\n  \"access_latency_histogram\":[";
        for(unsigned i=0;i<64;++i)f << (i?",":"") << access_latencies[i];
        f << "],\n  \"latency_last_bucket\":\"63 or more clocks\",\n  \"interval_hot_pages\":[";
        std::vector<std::pair<uint32_t,uint64_t>> ordered(pages.begin(),pages.end());
        std::sort(ordered.begin(),ordered.end(),[](auto a,auto b){return a.second>b.second;});
        for(size_t i=0;i<std::min<size_t>(ordered.size(),12);++i){
            f << (i?",":"") << "{\"page\":\"" << std::hex << std::setw(8) << ordered[i].first
              << std::dec << "\",\"instructions\":" << ordered[i].second << '}';
        }
        f << "],\n  \"scanout_image_complete_frame\":false,\"scanout_coordinates_clipped\":" << (clipped?"true":"false")
          << ",\"scanout_rect\":[" << min_x << ',' << min_y << ',' << max_x << ',' << max_y
          << "],\"memories_saved\":" << (memories?"true":"false")
          << ",\"complete_scanout\":{\"width\":" << frames.width << ",\"height\":" << frames.height
          << ",\"completed\":" << frames.completed << ",\"rejected\":" << frames.rejected
          << ",\"start_clock\":" << frames.complete_start_clock << ",\"end_clock\":" << frames.complete_end_clock
          << ",\"image_saved\":" << (frames.completed?"true":"false")
          << ",\"source_kind\":\"actual pending scanout word and committed FIFO tag_base\",\"unknown_source_pixels\":" << frames.complete_unknown
          << ",\"fifo_source_bases\":[";
        bool first_base=true;
        for(auto [base,count]:frames.complete_bases){
            f<<(first_base?"":",")<<"{\"byte_offset\":"<<base<<",\"pixels\":"<<count<<'}';first_base=false;
        }
        f<<"],\"source_map\":\"scanout_complete_fifo_sources.u32le\",\"unknown_source_value\":4294967295}\n}\n";
        if(!f)throw std::runtime_error("private boot metadata write failed");
        if(frames.completed){
            std::ofstream full(stem+"/scanout_complete.ppm",std::ios::binary|std::ios::trunc);
            full << "P6\n" << frames.width << ' ' << frames.height << "\n255\n";
            full.write(reinterpret_cast<const char*>(frames.complete.data()),frames.complete.size());
            if(!full)throw std::runtime_error("private complete scanout frame write failed");
            std::ofstream source_map(stem+"/scanout_complete_fifo_sources.u32le",std::ios::binary|std::ios::trunc);
            for(uint32_t base:frames.complete_sources){const char bytes[4]={char(base),char(base>>8),char(base>>16),char(base>>24)};source_map.write(bytes,4);}
            if(!source_map)throw std::runtime_error("private scanout source map write failed");
        }
        if(!memories)return;
        raw(stem,"workram.bin",memory.ram.data(),0x800000);
        raw(stem,"texture.bin",memory.ram.data()+0x800000,0x800000);
        raw(stem,"framebuffer.bin",memory.ram.data()+0x1000000,0x800000);
        raw(stem,"nvram.bin",memory.nvram.data(),memory.nvram.size());
        raw(stem,"reset_ram.bin",memory.reset_ram.data(),memory.reset_ram.size());
        if(min_x<=max_x && min_y<=max_y){
            std::ofstream ppm(stem+"/scanout_partial.ppm",std::ios::binary|std::ios::trunc);
            ppm << "P6\n" << max_x-min_x+1 << ' ' << max_y-min_y+1 << "\n255\n";
            for(unsigned y=min_y;y<=max_y;++y)
                ppm.write(reinterpret_cast<const char*>(rgb.data()+(y*1024+min_x)*3),(max_x-min_x+1)*3);
            if(!ppm)throw std::runtime_error("private scanout image write failed");
        }
    }
    void observe(){
        if(d.retire)++pages[d.retire_pc&0xfffff000];
        if(d.cpu_irq_ack)++irq_acks;
        if(d.video_tick){
            if(d.video_vblank && !previous_vblank)++raster_frames;
            previous_vblank=d.video_vblank;
            if(d.video_de){
                ++active_pixels;
                pixel_source.verify(d);
                frames.pixel(clock,d.video_x,d.video_y,d.video_r,d.video_g,d.video_b,pixel_source.known?pixel_source.base:UINT32_MAX);
                if(d.video_x<1024 && d.video_y<1024){
                    const unsigned x=d.video_x,y=d.video_y,at=(y*1024+x)*3;
                    rgb[at]=d.video_r;rgb[at+1]=d.video_g;rgb[at+2]=d.video_b;
                    min_x=std::min(min_x,x);min_y=std::min(min_y,y);max_x=std::max(max_x,x);max_y=std::max(max_y,y);
                }else clipped=true;
            }
        }
        if(clock && clock%report_period==0){row();snapshot("latest",false);pages.clear();}
        active_packet_completed=d.gpu_packets!=previous_packets && d.gpu_pixels;
        previous_packets=d.gpu_packets;
        if(active_packet_completed && !first_gpu_saved){
            first_gpu_saved=true;context_trace_closed=true;row();snapshot("first_gpu_packet",true);
        }
    }
};
