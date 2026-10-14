#include <unordered_map>
// SPDX-License-Identifier: GPL-3.0-or-later
#ifdef CS_PHYSICAL_MEMORY
#ifdef CS_HOST_LOADER
#include "Vcs_crystal_platform.h"
#ifndef CS_SOUND_FIXTURE
#include "Vcs_crystal_platform___024root.h"
#define CS_SCAN(field) dut.rootp->cs_crystal_platform__DOT__board__DOT__board__DOT__scanout__DOT__##field
#define CS_GB(field) dut.rootp->cs_crystal_platform__DOT__board__DOT__gpu_burst_##field
#define CS_PROBE(field) dut.rootp->cs_crystal_platform__DOT__board__DOT__board__DOT__##field
#endif
using Vcs_boot_probe = Vcs_crystal_platform;
#else
#include "Vcs_crystal_board.h"
#ifndef CS_SOUND_FIXTURE
#include "Vcs_crystal_board___024root.h"
#define CS_SCAN(field) dut.rootp->cs_crystal_board__DOT__board__DOT__scanout__DOT__##field
#define CS_GB(field) dut.rootp->cs_crystal_board__DOT__gpu_burst_##field
#define CS_PROBE(field) dut.rootp->cs_crystal_board__DOT__board__DOT__##field
#endif
using Vcs_boot_probe = Vcs_crystal_board;
#endif
#include "../memory/sdram_model.hpp"
#ifdef CS_TIMED_SDRAM
#include "../memory/sdram_timed_port.hpp"
#endif
#include "../memory/ddr_model.hpp"
#else
#include "Vcs_boot_probe.h"
#ifndef CS_SOUND_FIXTURE
#include "Vcs_boot_probe___024root.h"
#define CS_SCAN(field) dut.rootp->cs_boot_probe__DOT__scanout__DOT__##field
#define CS_PROBE(field) dut.rootp->cs_boot_probe__DOT__##field
#endif
#endif
#include "verilated.h"
#include <cstdlib>
// CPU bus adapter internals for the FETCH_PAIR oracle hook (observation only).
#if defined(CS_PHYSICAL_MEMORY) && defined(CS_HOST_LOADER)
#include "Vcs_crystal_platform___024root.h"
#define CS_AU(field) dut.rootp->cs_crystal_platform__DOT__board__DOT__board__DOT__cpu__DOT__access_unit__DOT__##field
#define CS_CPUR(field) dut.rootp->cs_crystal_platform__DOT__board__DOT__board__DOT__cpu__DOT__##field
#elif defined(CS_PHYSICAL_MEMORY)
#include "Vcs_crystal_board___024root.h"
#define CS_AU(field) dut.rootp->cs_crystal_board__DOT__board__DOT__cpu__DOT__access_unit__DOT__##field
#define CS_CPUR(field) dut.rootp->cs_crystal_board__DOT__board__DOT__cpu__DOT__##field
#else
#include "Vcs_boot_probe___024root.h"
#define CS_AU(field) dut.rootp->cs_boot_probe__DOT__cpu__DOT__access_unit__DOT__##field
#define CS_CPUR(field) dut.rootp->cs_boot_probe__DOT__cpu__DOT__##field
#endif
#include "../obj_dir/cpu_reference/se3208_reference.hpp"
#include "board_memory.hpp"
#ifndef CS_SOUND_FIXTURE
#include "boot_observer.hpp"
#include "cabinet_input.hpp"
#include "cpu_stats.hpp"
#endif
#ifdef CS_SOUND_FIXTURE
#include "sound_fixture.hpp"
#endif
#include <cstdio>
#include <fstream>
#include <memory>
#include <vector>
#include <string>
#ifdef CS_CHECKPOINT
#include "checkpoint.hpp"
#endif
static vluint64_t ticks=0;
double sc_time_stamp(){return double(ticks);}
static uint32_t rng=0x43535953;
static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;return rng^=rng<<5;}
static std::vector<uint8_t> load(const char* path){std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error(std::string("missing ROM: ")+path);return {std::istreambuf_iterator<char>(f),std::istreambuf_iterator<char>()};}
static void bytes(std::vector<std::pair<uint32_t,uint8_t>>& trace,uint32_t address,uint32_t data,unsigned lanes){for(unsigned i=0;i<4;++i)if(lanes&(1<<i))trace.emplace_back(address+i,uint8_t(data>>(i*8)));}
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
#ifdef CS_CHECKPOINT
    checkpoint_binary_mode();
    const std::string restore_path=checkpoint_env("CS_CHECKPOINT_RESTORE");
#endif
#ifdef CS_SOUND_FIXTURE
    const auto bios=sound_fixture_bios();const std::vector<uint8_t> flash(256,255);
    bool sound_started=false;unsigned sound_outputs=0,irq_acks=0,cabinet_reads=0;int32_t expected_left=0,expected_right=0;
    sound_fixture_reference_reset();
#else
    // CS_GAME=<set> selects scripts/stage_game_images.py images (cart = populated banks, then BIOS);
    // default: the original crysking staging (roms/images/crysking.bin + bios.bin).
    const std::string game=std::getenv("CS_GAME")?std::getenv("CS_GAME"):"";
    const std::string bios_path=game.empty()?"roms/images/bios.bin":"roms/images/"+game+"_bios.bin",
               cart_path=game.empty()?"roms/images/crysking.bin":"roms/images/"+game+"_cart.bin";
    const auto bios=load(bios_path.c_str()),flash=load(cart_path.c_str());
    if(flash.size()%0x1000000||flash.empty()||flash.size()>0x7000000)throw std::runtime_error("cartridge image must be 1-7 whole 16 MiB banks");
#endif
    Memory memory(bios,flash);
    auto reference=std::make_unique<se3208_device>();
    std::vector<std::pair<uint32_t,uint8_t>> cpu_reads,cpu_writes,reference_writes;
    std::vector<uint8_t> events,reference_events;
    size_t consumed=0;bool replay=false,irq_seen=false;uint8_t vector_seen=0;
    // FETCH_PAIR: the CPU takes the next sequential opcode from the upper half of
    // its previous fetch reply without a new request. Replay those two bytes from
    // that recorded reply so the reference still observes every fetch read.
    uint32_t pair_address=0,pair_word=0;bool pair_word_valid=false,pair_logged=false;
    // PREFETCH: a speculative next-word fetch is replayed only if the CPU
    // consumes it as its next fetch; a discarded one is never read by MAME.
    uint32_t pf_address=0,pf_word=0;unsigned pf_strobe=0;bool pf_valid=false,pf_previous=false;
    reference->m_program.external_read=[&](uint32_t a){
        if(!replay)return memory.read(a);
        if(consumed>=cpu_reads.size() || cpu_reads[consumed].first!=a)throw std::runtime_error("CPU read address/order divergence");
        return cpu_reads[consumed++].second;
    };
    reference->m_program.external_write=[&](uint32_t a,uint8_t v){reference_writes.emplace_back(a,v);};
    reference->m_machinex_cb=[&](uint8_t code){reference_events.push_back(code);};
    reference->m_iackx_cb=[&](){return vector_seen;};
    reference->device_reset();replay=true;
    Vcs_boot_probe dut;dut.p1_p2_n=0xffffffff;dut.p3_p4_n=0xffffffff;dut.system_n=0xff;dut.dips_n=0xff;dut.reset=1;
    dut.cart_banks=uint8_t(flash.size()>>24); // MRA board record bank count
    // Optional diagnostic: CS_DIPS=hex overrides the active-low DIP byte (MiSTer saved switches).
    if(const char* dips=std::getenv("CS_DIPS"))dut.dips_n=uint8_t(std::stoul(dips,nullptr,16));
#ifdef CS_PHYSICAL_MEMORY
    SdramModel sdram;DdrModel ddr;
    // Real MiSTer SDRAM keeps the previous core's contents; optional garbage fill.
    if(const char* fill=std::getenv("CS_SDRAM_FILL_SEED")){
        uint32_t s=uint32_t(std::strtoul(fill,nullptr,0))|1u;
        for(auto& w:sdram.words){s^=s<<13;s^=s>>17;s^=s<<5;w=uint16_t(s);}
        // The checker's board RAM shadow must start with the same physical contents
        // (main/texture/frame RAM are linear halfwords at SDRAM byte 0..0x17fffff).
        for(size_t b=0;b<memory.ram.size();++b) memory.ram[b]=uint8_t(sdram.words[b>>1]>>((b&1)*8));
        std::printf("SDRAM_FILL seed=%s\n",fill);
    }
#ifdef CS_TIMED_SDRAM
    #ifdef CS_SDRAM_LATE_CAPTURE
    TimedSdramPort<true> sdram_pins(sdram,SdramPinProfile::selected(),true);
    const char* phase_text=std::getenv("CS_SDRAM_CAPTURE_PHASE_NS");
    if(!phase_text)throw std::runtime_error("missing fitted capture phase");
    sdram_pins.capture_phase=std::stod(phase_text);
#else
    TimedSdramPort<> sdram_pins(sdram,SdramPinProfile::selected(),true);
#endif
#endif
    // Original images populate simulated physical DDR, never CPU state/live RAM.
#ifndef CS_HOST_LOADER
    std::copy(flash.begin(),flash.end(),ddr.bytes.begin());
    std::copy(bios.begin(),bios.end(),ddr.bytes.begin()+flash.size());
    dut.load_valid=0;
#else
    dut.ioctl_download=0;dut.ioctl_wr=0;dut.ioctl_index=0;
#endif
    dut.memory_reset=1;dut.backup_valid=0;
    auto physical_finish=[&](){
        #ifdef CS_TIMED_SDRAM
        sdram_pins.prepare(dut);ddr.finish(dut,false);ticks+=2;sdram_pins.finish(dut);
#else
        ddr.finish(dut);ticks+=2;
        dut.sdram_data_in=sdram.tick(dut.sdram_cke,dut.sdram_cs_n,dut.sdram_ras_n,
            dut.sdram_cas_n,dut.sdram_we_n,dut.sdram_ba,dut.sdram_address,
            dut.sdram_dqm,dut.sdram_data_out,dut.sdram_data_oe);dut.eval();
#endif
    };
#ifdef CS_CHECKPOINT
    if(restore_path.empty()){
#endif
    for(unsigned i=0;i<4;++i){dut.ce=i&1;ddr.prepare(dut);physical_finish();}
    dut.memory_reset=0;
#ifdef CS_HOST_LOADER
    // Drive genuine HPS byte transfers, including waitrequest and actual DDR
    // completion. CPU/chips stay reset; no live RAM or architectural injection.
    // MRA image order is the DDR3 order: 48 MiB cartridge, then 128 KiB BIOS.
    // CS_HOST_DIRECT=1 models Main_MiSTer's address="0x30000000" path: the HPS
    // writes DDR3 itself and only announces the image length (no ioctl_wr).
    const bool host_direct=std::getenv("CS_HOST_DIRECT")!=nullptr;
    dut.ioctl_download=1;
    if(host_direct){
        std::copy(flash.begin(),flash.end(),ddr.bytes.begin());
        std::copy(bios.begin(),bios.end(),ddr.bytes.begin()+flash.size());
        dut.ioctl_addr=uint32_t(flash.size()+bios.size());
        for(unsigned i=0;i<64;++i){ddr.prepare(dut);physical_finish();}
        dut.ioctl_addr=uint32_t(flash.size()+bios.size()+1);
    }else for(uint32_t address=0;address<bios.size()+flash.size();++address){
        while(dut.ioctl_wait){ddr.prepare(dut);physical_finish();}
        dut.ioctl_addr=address;dut.ioctl_dout=address<flash.size()?flash[address]:bios[address-flash.size()];
        dut.ioctl_wr=1;ddr.prepare(dut);physical_finish();dut.ioctl_wr=0;
        if(dut.loader_error || dut.retire || dut.req_valid)throw std::runtime_error("host loader error or premature core release");
    }
    while(dut.ioctl_wait){ddr.prepare(dut);physical_finish();}
    dut.ioctl_download=0;
    for(unsigned i=0;i<64 && (dut.loading || !dut.rom_ready);++i){ddr.prepare(dut);physical_finish();}
    for(unsigned i=0;i<4;++i){ddr.prepare(dut);physical_finish();}
    if(!dut.rom_ready || dut.loader_error || !std::equal(flash.begin(),flash.end(),ddr.bytes.begin()) ||
       !std::equal(bios.begin(),bios.end(),ddr.bytes.begin()+flash.size()))throw std::runtime_error("host-loaded physical ROM differs from staged images");
    std::printf("HOST ROM LOAD: %llu clocks, %llu physical DDR writes; complete BIOS/cart readback match, board held reset\n",(unsigned long long)ddr.cycles,(unsigned long long)ddr.writes);
#endif
#ifndef CS_SOUND_FIXTURE
    // Protection PIC firmware (MRA index 3, staged as roms/images/<set>_pic.bin): the words the top
    // level packs from the index-3 bytes, written while the board is held in reset.
    if(!game.empty()){
        const std::string pic_path="roms/images/"+game+"_pic.bin";
        if(std::FILE* pic_file=std::fopen(pic_path.c_str(),"rb")){
            std::fclose(pic_file);
            const auto pic=load(pic_path.c_str());
            dut.pic_enable=1;
            for(size_t i=0;i+1<pic.size();i+=2){
                dut.pic_load_we=1;dut.pic_load_address=uint16_t(i>>1);dut.pic_load_data=uint16_t(pic[i]|pic[i+1]<<8);
                ddr.prepare(dut);physical_finish();
            }
            dut.pic_load_we=0;ddr.prepare(dut);physical_finish();
            std::printf("PIC firmware %s: %zu words loaded, PIC enabled\n",pic_path.c_str(),pic.size()/2);
        }
    }
#endif
    dut.reset=0;
#ifdef CS_CHECKPOINT
    }
#endif
#else
    dut.req_ready=0;dut.rsp_valid=0;dut.rsp_error=0;
    for(unsigned i=0;i<4;++i){dut.clk=0;dut.ce=i&1;dut.eval();++ticks;dut.clk=1;dut.eval();++ticks;}dut.reset=0;
#endif
    bool pending=false,error=false,stopped_device=false,skip_reset_vector=true;
    unsigned delay=0,instructions=0,requests=0,mmios=0,stop_target=15;
    std::array<uint64_t,5> client_requests{};uint64_t sound_mmios=0,audio_samples=0,audio_nonzero=0;
    uint32_t last_memory=0,last_mmio=0;
    const uint64_t max_clocks=argc>1?std::stoull(argv[1]):std::getenv("CS_MAX_CLOCKS")?std::stoull(std::getenv("CS_MAX_CLOCKS")):
#ifdef CS_SOUND_FIXTURE
        80000;
#else
        250000000;
#endif
    uint32_t reply=0,stop_address=0;bool pending_write=false;
    uint64_t stall_run=0,stall_max=0,stall_total=0,stall_full=0,stall_hold=0;uint64_t stall_max_at=0;unsigned stall_max_occ=0;uint64_t frame_burst_reads=0,texture_writes=0,texture_writes_pending=0,texture_races=0,submitted_total=0;unsigned previous_front=0;
    std::unordered_map<uint32_t,uint64_t> texture_line_write_seq; // 32-byte texture line -> packets submitted at its last write
    bool gb_pending=false,gb_done=false;unsigned gb_delay=0;uint32_t gb_data[8]{};
    std::array<std::pair<uint32_t,uint16_t>,16> tail{};
    bool architectural_pending=false,architectural_write=false,control_pending=false;
    uint32_t architectural_address=0,architectural_data=0,control_input=0,control_read=0;
    unsigned architectural_strobe=0,control_id=0,control_register=0;
    bool control_write=false,control_error=false,control_completed=false;
    uint64_t control_transactions=0;

#ifndef CS_SOUND_FIXTURE
    const uint32_t stop_packets=argc>2?std::stoul(argv[2]):0;
    BootObserver observer(dut,memory,instructions,requests,mmios,client_requests,
                          control_transactions,sound_mmios,audio_samples,audio_nonzero);
    if(argc>3)observer.report_period=std::max<uint64_t>(1,std::stoull(argv[3]));
    CabinetInput cabinet(argc>4?argv[4]:observer.ROOT+"/cabinet_commands.txt",observer.ROOT+"/cabinet_inputs.csv");
    std::printf("CABINET live commands: %s (physical pins only)\n",cabinet.command_path.c_str());
#endif

    uint64_t first_clock=0;
#ifndef CS_SOUND_FIXTURE
    CpuStats cpu_stats;
#endif
#ifdef CS_CHECKPOINT
    auto external_state=[&](CheckpointArchive& a){
        if(!reference->m_program.bytes.empty()||!reference->m_program.writes.empty()||reference->m_program.trace_writes)
            throw std::runtime_error("checkpoint oracle bus has untracked internal storage");
        a(ticks,rng,reference->m_R,reference->m_PC,reference->m_SR,reference->m_SP,reference->m_ER,
          reference->m_PPC,reference->m_IRQ,reference->m_NMI,reference->m_icount,
          cpu_reads,cpu_writes,reference_writes,events,reference_events,consumed,replay,irq_seen,vector_seen,
          pair_address,pair_word,pair_word_valid,pair_logged,
          pf_address,pf_word,pf_strobe,pf_valid,pf_previous,
          pending,error,stopped_device,skip_reset_vector,delay,instructions,requests,mmios,stop_target,
          client_requests,sound_mmios,audio_samples,audio_nonzero,last_memory,last_mmio,reply,stop_address,pending_write,
          tail,architectural_pending,architectural_write,control_pending,architectural_address,architectural_data,
          control_input,control_read,architectural_strobe,control_id,control_register,control_write,control_error,
          control_completed,control_transactions);
        checkpoint_memory(a,memory,sdram,ddr);checkpoint_observer(a,observer,cabinet);
#ifdef CS_TIMED_SDRAM
        a(sdram_pins.cycles,sdram_pins.dq,sdram_pins.returns);
#endif
    };
    if(!restore_path.empty())first_clock=restore_checkpoint(restore_path,dut,external_state);
    uint64_t next_checkpoint=checkpoint_number("CS_CHECKPOINT_AT");
    const uint64_t checkpoint_period=checkpoint_number("CS_CHECKPOINT_PERIOD");
    const uint64_t checkpoint_end=checkpoint_number("CS_CHECKPOINT_STOP_AT");
#ifdef CS_TIMED_SDRAM
    const bool checkpoint_pending_dq=checkpoint_number("CS_CHECKPOINT_PENDING_DQ")!=0;
#endif
#endif
    for(uint64_t clock=first_clock;clock<max_clocks;++clock){
#ifndef CS_SOUND_FIXTURE
        cabinet.tick(clock,observer.raster_frames,dut);
        observer.cabinet_commands=cabinet.commands;observer.cabinet_releases=cabinet.releases;
        observer.cabinet_sequence=cabinet.last_sequence;
#endif
        dut.ce=clock&1;
#ifdef CS_PHYSICAL_MEMORY
        ddr.prepare(dut);
        if(!dut.memory_initialized && (dut.retire || dut.req_valid || dut.video_tick || dut.audio_valid)){
            std::fprintf(stderr,"FAIL board escaped power-up reset before physical SDRAM readiness\n");return 1;
        }
        if(dut.rsp_valid && (!pending || bool(dut.rsp_error)!=error || (!error && !pending_write && dut.rsp_data!=reply))){
            std::fprintf(stderr,"FAIL physical memory response owner/data/error: address=%08x actual=%08x expected=%08x error=%u/%u\n",last_memory,dut.rsp_data,reply,dut.rsp_error,error);return 1;
        }
#else
        dut.clk=0;dut.req_ready=!pending && ((random32()&3)!=0);
        // GPU 32-byte line burst port, served from the same byte-level board memory.
        dut.gpu_burst_ready=!gb_pending&&!gb_done&&((random32()%3)!=0);dut.gpu_burst_done=gb_done;
        for(unsigned w=0;w<8;w++)dut.gpu_burst_rdata[w]=gb_data[w];
        dut.rsp_valid=pending && !delay;dut.rsp_data=reply;dut.rsp_error=error;dut.eval();++ticks;
        const bool gb_accept=dut.gpu_burst_valid&&dut.gpu_burst_ready;const bool gb_write=dut.gpu_burst_write,gb_frame=dut.gpu_burst_region;
        const uint32_t gb_base=(dut.gpu_burst_region?0x04000000u:0x03800000u)+((uint32_t(dut.gpu_burst_line)<<5)&0x7fffff);
        const uint32_t gb_strobe=dut.gpu_burst_wstrobe;uint32_t gb_wdata[8];for(unsigned w=0;w<8;w++)gb_wdata[w]=dut.gpu_burst_wdata[w];
#endif
        const bool accepted=dut.req_valid && dut.req_ready,responded=dut.rsp_valid;
#if defined(CS_PHYSICAL_MEMORY) && !defined(CS_SOUND_FIXTURE)
        {const bool blk=CS_PROBE(a_valid)&&!CS_PROBE(a_ready);
         if(blk){++stall_run;++stall_total;}else{if(stall_run>stall_max){stall_max=stall_run;stall_max_at=clock;stall_max_occ=unsigned(CS_PROBE(texq__DOT__wr_ptr)-CS_PROBE(texq__DOT__rd_ptr))&0x1fff;}stall_run=0;}}
        // Texture-race census (crystal_texq question): a CPU/DMA texture-RAM write accepted while the renderer
        // still has packets that were submitted before it (queue front != rear, or busy) could be seen by them.
        {const unsigned front=CS_PROBE(gpu__DOT__queue_front);submitted_total+=(front-previous_front)&0x7ff;previous_front=front;}
        // True race: the renderer reads a texture line for a packet submitted before that line's last
        // CPU/DMA write (MAME renders the packet before the write; this renderer is later).
        if(CS_GB(valid)&&CS_GB(ready)&&!CS_GB(write)&&!CS_GB(region)){auto it=texture_line_write_seq.find(CS_GB(line));
            if(it!=texture_line_write_seq.end()&&uint64_t(dut.gpu_packets)<it->second)++texture_races;}
        if(accepted && dut.req_write && dut.req_target==2){texture_line_write_seq[(dut.req_offset>>5)&0x3ffff]=submitted_total;++texture_writes;
            if(CS_PROBE(gpu__DOT__queue_front)!=CS_PROBE(gpu__DOT__queue_rear)||CS_PROBE(gpu__DOT__state)!=0)++texture_writes_pending;}
#endif
        const uint32_t address=dut.req_address,data=dut.req_data,offset=dut.req_offset;
        memory.bank=dut.flash_bank;
        const unsigned target=dut.req_target,strobe=dut.req_strobe,client=dut.req_client;const bool write=dut.req_write;
        const bool mmio=dut.mmio_valid && dut.mmio_ready,mmio_write=dut.mmio_write;
        const uint32_t mmio_address=dut.mmio_address,mmio_data=dut.mmio_data;const unsigned mmio_strobe=dut.mmio_strobe;
        const bool architectural_accept=dut.cpu_trace_valid && dut.cpu_trace_ready;
        const uint32_t architectural_accept_address=dut.cpu_trace_address,architectural_accept_data=dut.cpu_trace_data;
        const unsigned architectural_accept_strobe=dut.cpu_trace_strobe;
        const bool architectural_accept_write=dut.cpu_trace_write;
        const bool control_accept=dut.cp_req_valid && dut.cp_req_ready;
        const bool control_reply=dut.cp_rsp_valid && dut.cp_rsp_ready;
        const unsigned accepted_control_id=dut.cp_req_id,accepted_control_register=dut.cp_req_register;
        const uint32_t accepted_control_data=dut.cp_req_data,returned_control_data=dut.cp_rsp_data;
        const bool accepted_control_write=dut.cp_req_write,returned_control_error=dut.cp_rsp_error;
#ifndef CS_SOUND_FIXTURE
        observer.pixel_source=scanout_source(CS_SCAN(pixel_pending),CS_SCAN(pending_de),
            CS_SCAN(pending_visible),CS_SCAN(pending_ready),CS_SCAN(pending_armed),
            CS_SCAN(pending_x),CS_SCAN(pending_y),CS_SCAN(pixel_word),CS_SCAN(pending_half),
            CS_SCAN(tag_y)[CS_SCAN(pending_y)&1],CS_SCAN(tag_base)[CS_SCAN(pending_y)&1]);
#endif
#ifdef CS_PHYSICAL_MEMORY
#ifndef CS_SOUND_FIXTURE
        // GPU line bursts bypass the shared request port: mirror accepted burst writes into
        // the independent memory oracle so later CPU/scanout reads are still checked.
        if(CS_GB(valid)&&CS_GB(ready)&&CS_GB(write)){
            const uint32_t base=(CS_GB(region)?0x04000000u:0x03800000u)+((uint32_t(CS_GB(line))<<5)&0x7fffff);
            const uint32_t strobes=CS_GB(wstrobe);
            for(unsigned w=0;w<8;w++)for(unsigned lane=0;lane<4;++lane)
                if((strobes>>(4*w+lane))&1)memory.write(base+w*4+lane,uint8_t(CS_GB(wdata)[w]>>(lane*8)));
        }
#endif
        physical_finish();
#else
        dut.clk=1;dut.eval();++ticks;
        if(gb_done)gb_done=false;
        if(gb_pending){if(gb_delay)--gb_delay;else{gb_pending=false;gb_done=true;}}
        if(gb_accept&&!gb_write&&gb_frame)++frame_burst_reads;
        if(gb_accept){
            for(unsigned w=0;w<8;w++){
                const uint32_t a=gb_base+w*4;
                if(gb_write){for(unsigned lane=0;lane<4;++lane)if((gb_strobe>>(4*w+lane))&1)memory.write(a+lane,uint8_t(gb_wdata[w]>>(lane*8)));}
                else{gb_data[w]=0;for(unsigned lane=0;lane<4;++lane)gb_data[w]|=uint32_t(memory.read(a+lane))<<(lane*8);}
            }
            gb_pending=true;gb_delay=random32()%24;
        }
#endif

#ifndef CS_SOUND_FIXTURE
        observer.clock=clock;
#endif
        if(architectural_accept){
            if(architectural_pending){std::fprintf(stderr,"FAIL overlapping architectural CPU requests\n");return 1;}
#ifndef CS_SOUND_FIXTURE
            observer.accepted(clock);
#endif
            architectural_pending=true;architectural_address=architectural_accept_address;
            architectural_data=architectural_accept_data;architectural_strobe=architectural_accept_strobe;
            architectural_write=architectural_accept_write;
        }
        if(dut.cpu_trace_rsp_valid){
            if(!architectural_pending){std::fprintf(stderr,"FAIL unsolicited architectural CPU reply\n");return 1;}
#ifndef CS_SOUND_FIXTURE
            observer.responded(clock);
#endif
            if(!dut.cpu_trace_rsp_error){
                if(architectural_write)bytes(cpu_writes,architectural_address,architectural_data,architectural_strobe);
                else if(skip_reset_vector){
                    if(architectural_address!=0 || architectural_strobe!=15){std::fprintf(stderr,"FAIL architectural reset vector\n");return 1;}
                    skip_reset_vector=false;
                } else if(CS_CPUR(pf_pending)){
                    pf_address=architectural_address;pf_word=dut.cpu_trace_rsp_data;pf_strobe=architectural_strobe;pf_valid=true;
                } else {
                    bytes(cpu_reads,architectural_address,dut.cpu_trace_rsp_data,architectural_strobe);
                    pair_address=architectural_address;pair_word=dut.cpu_trace_rsp_data;pair_word_valid=true;
                }
            } else pair_word_valid=false;
            if(architectural_write)pair_word_valid=false;
            architectural_pending=false;
        }
        {   // Prefetch resolved: consumed as the next fetch (CPU now in EXECUTE) or dropped.
            const bool pf_now=CS_CPUR(pf_pending);
            if(pf_previous && !pf_now){
                if(CS_CPUR(state)==2){
                    if(!pf_valid){std::fprintf(stderr,"FAIL consumed prefetch without a recorded reply\n");return 1;}
                    bytes(cpu_reads,pf_address,pf_word,pf_strobe);
                    pair_address=pf_address;pair_word=pf_word;pair_word_valid=true;
                } else pair_word_valid=false;
                pf_valid=false;
            }
            pf_previous=pf_now;
        }
        {   // Bus adapter RESULT (3) held by a size-3 paired fetch command; record the
            // read when the CPU consumes it (after the previous instruction retired).
            const bool paired=CS_AU(state)==3 && CS_AU(size)==3;
            if(pair_logged && !paired){
                if(!pair_word_valid || (pair_address&3)!=0){std::fprintf(stderr,"FAIL paired fetch without an aligned preceding fetch reply\n");return 1;}
                bytes(cpu_reads,pair_address,pair_word,0xc);
            }
            pair_logged=paired;
        }
        if(control_accept){
            if(control_pending || control_completed){std::fprintf(stderr,"FAIL overlapping coprocessor transfers\n");return 1;}
            control_pending=true;control_id=accepted_control_id;control_register=accepted_control_register;
            control_input=accepted_control_data;control_write=accepted_control_write;
        }
        if(control_reply){
            if(!control_pending){std::fprintf(stderr,"FAIL unsolicited coprocessor reply\n");return 1;}
            control_pending=false;control_completed=true;control_read=returned_control_data;
            control_error=returned_control_error;++control_transactions;
        }

        #ifndef CS_SOUND_FIXTURE
        if(responded)observer.bus_reply(dut.rsp_data,dut.rsp_error);
#endif
        if(pending && delay)--delay;if(responded)pending=false;
        if(accepted){
            if(pending || (address&3)){std::fprintf(stderr,"FAIL bus protocol\n");return 1;}
            if(client>=5){std::fprintf(stderr,"FAIL memory owner index\n");return 1;}++client_requests[client];
            #ifndef CS_SOUND_FIXTURE
            observer.bus_accept(client,target,address,data,strobe,write);
#endif
            last_memory=address;
            ++requests;pending=true;pending_write=write;error=false;reply=0;
#ifndef CS_PHYSICAL_MEMORY
            delay=1+random32()%7;
#endif
            if(memory.decode(address)!=std::make_pair(target,offset)){std::fprintf(stderr,"FAIL RTL address map %08x\n",address);return 1;}
#ifndef CS_SOUND_FIXTURE
            if(client==2)observer.gpu_begin();
#endif
            try{
                if(write){for(unsigned lane=0;lane<4;++lane)if(strobe&(1<<lane))memory.write(address+lane,uint8_t(data>>(lane*8)));}
                else{
                    for(unsigned lane=0;lane<4;++lane)reply|=uint32_t(memory.read(address+lane))<<(lane*8);

                }
            }catch(const std::exception&){error=true;stopped_device=true;stop_address=address;stop_target=target;}
#ifndef CS_SOUND_FIXTURE
            observer.memory_access(client,target,address,data,strobe,write,reply,error);
#endif
        }
        if(mmio){
#ifndef CS_SOUND_FIXTURE
            if(mmio_address>=0x04800000 && mmio_address<=0x04800fff)
                observer.sound_access(mmio_address,mmio_write?mmio_data:dut.mmio_rsp_data,mmio_strobe,mmio_write,dut.mmio_rsp_error);
            if(mmio_write && mmio_address>=0x03000000 && mmio_address<=0x0300ffff)
                observer.video_write(mmio_address,mmio_data,mmio_strobe,dut.mmio_rsp_error);
#endif

            last_mmio=mmio_address;
            // Optional diagnostic: CS_TRACE_MMIO=1 lists every MMIO access with the retire count.
            static const bool trace_mmio=std::getenv("CS_TRACE_MMIO")!=nullptr;
            if(trace_mmio)std::fprintf(stderr,"MMIO #%u %c %08x data=%08x strobe=%x\n",instructions,mmio_write?'W':'R',mmio_address,mmio_write?mmio_data:uint32_t(dut.mmio_rsp_data),mmio_strobe);
            ++mmios;if(mmio_address>=0x04800000&&mmio_address<=0x04800fff)++sound_mmios;
#ifdef CS_SOUND_FIXTURE
            if(!mmio_write && mmio_address==0x01200008){
                if(!dut.cache_enabled){std::fprintf(stderr,"FAIL cabinet input read with cache disabled\n");return 1;}
                ++cabinet_reads;dut.dips_n=0x7f;
            }

            if(mmio_write&&mmio_address==0x04800600&&(mmio_data&0x80000000))sound_started=true;
            if(!mmio_write&&mmio_address==0x01800c0c&&dut.mmio_rsp_data!=4){std::fprintf(stderr,"FAIL sound IRQ routing/status\n");return 1;}
#endif
            if(!dut.mmio_rsp_valid){std::fprintf(stderr,"FAIL internal MMIO response missing\n");return 1;}
            if(dut.mmio_rsp_error){stopped_device=true;stop_address=mmio_address;stop_target=6;}
        }
        if(dut.cpu_irq_ack){irq_seen=true;vector_seen=dut.irq_vector;
#ifdef CS_SOUND_FIXTURE
            if(vector_seen!=2){std::fprintf(stderr,"FAIL sound vector %u\n",vector_seen);return 1;}++irq_acks;
#endif
        }
        if(dut.cpu_event)events.push_back(dut.cpu_event_code);
        if(dut.retire){
            if(dut.retire_pc!=reference->m_PC){std::fprintf(stderr,"FAIL retirement PC %08x/%08x\n",dut.retire_pc,reference->m_PC);return 1;}
            reference->m_IRQ=irq_seen?1:0;consumed=0;reference_writes.clear();reference_events.clear();
            const bool control_instruction=(dut.retire_opcode&0xfcf0)==0xfc60;
            if(control_instruction){
                if(!control_completed || control_error || control_id!=((dut.retire_opcode>>8)&3) ||
                   control_register!=(dut.retire_opcode&7) || control_write!=!(dut.retire_opcode&8) ||
                   control_input!=reference->m_R[0]){
                    std::fprintf(stderr,"FAIL architectural coprocessor transfer metadata\n");return 1;
                }
            }else if(control_completed){std::fprintf(stderr,"FAIL coprocessor result attached to another instruction\n");return 1;}
            try{reference->step();}catch(const std::exception& e){std::fprintf(stderr,"FAIL oracle #%u PC=%08x: %s\n",instructions,dut.retire_pc,e.what());return 1;}
            // Pinned MAME control handlers are empty. Primary SE3208 transfer
            // semantics consume the observed CP0 input, like MMIO read inputs.
            // This is an architectural oracle; CP0 device behavior is tested separately.
            if(control_instruction && !control_write)reference->m_R[0]=control_read;
            if(control_instruction)control_completed=false;
            bool same=dut.pc==reference->m_PC && dut.sr==reference->m_SR && dut.sp==reference->m_SP && dut.er==reference->m_ER && cpu_writes==reference_writes && events==reference_events && consumed==cpu_reads.size();
            for(unsigned i=0;i<8;++i)same &= dut.registers[i]==reference->m_R[i];
            if(!same){std::fprintf(stderr,"FAIL CPU firmware divergence #%u PC=%08x opcode=%04x nextPC=%08x/%08x SR=%08x/%08x SP=%08x/%08x ER=%08x/%08x reads=%zu/%zu writes=%zu/%zu\n",instructions,dut.retire_pc,dut.retire_opcode,dut.pc,reference->m_PC,dut.sr,reference->m_SR,dut.sp,reference->m_SP,dut.er,reference->m_ER,consumed,cpu_reads.size(),cpu_writes.size(),reference_writes.size());return 1;}
            cpu_reads.clear();cpu_writes.clear();events.clear();irq_seen=false;memory.writes.clear();
            tail[instructions%tail.size()]={dut.retire_pc,dut.retire_opcode};++instructions;
            // Optional diagnostic: CS_WATCH_PC=hex[,hex...] prints the retire count and registers.
            static const std::vector<uint32_t> watch_pcs=[]{std::vector<uint32_t> v;if(const char* w=std::getenv("CS_WATCH_PC")){std::string s(w);size_t p=0;while(p<s.size()){size_t q=s.find(',',p);v.push_back(std::stoul(s.substr(p,q-p),nullptr,16));if(q==std::string::npos)break;p=q+1;}}return v;}();
            for(uint32_t w:watch_pcs)if(dut.retire_pc==w){std::fprintf(stderr,"WATCH #%u PC=%08x R0=%08x R1=%08x R2=%08x R3=%08x R4=%08x R5=%08x R6=%08x R7=%08x ER=%08x SR=%08x\n",instructions,dut.retire_pc,dut.registers[0],dut.registers[1],dut.registers[2],dut.registers[3],dut.registers[4],dut.registers[5],dut.registers[6],dut.registers[7],dut.er,dut.sr);}
        }
        if(dut.audio_valid){++audio_samples;if(dut.audio_left||dut.audio_right)++audio_nonzero;
#ifdef CS_SOUND_FIXTURE
            if(int16_t(dut.audio_left)!=expected_left||int16_t(dut.audio_right)!=expected_right){std::fprintf(stderr,"FAIL CPU-driven sound sample #%llu: %d/%d expected %d/%d\n",(unsigned long long)audio_samples,int16_t(dut.audio_left),int16_t(dut.audio_right),expected_left,expected_right);return 1;}
            if(sound_started){++sound_outputs;sound_fixture_reference_render(&expected_left,&expected_right);}
#endif
        }
        if(dut.video_fault||dut.video_underrun||dut.video_unsupported_geometry){std::fprintf(stderr,"FAIL video fault=%u underrun=%u geometry=%u address=%08x clock=%llu xy=%u/%u armed=%u words=%u clients=%llu/%llu/%llu/%llu/%llu\n",dut.video_fault,dut.video_underrun,dut.video_unsupported_geometry,dut.video_fault_address,(unsigned long long)clock,dut.video_x,dut.video_y,dut.video_armed,dut.video_words,(unsigned long long)client_requests[0],(unsigned long long)client_requests[1],(unsigned long long)client_requests[2],(unsigned long long)client_requests[3],(unsigned long long)client_requests[4]);return 1;}
        if(dut.audio_fault||dut.audio_underrun||dut.audio_unsupported_modes||dut.audio_unsupported_reverb){
#ifndef CS_SOUND_FIXTURE
            observer.audio_failure();
#endif
#if defined(CS_PHYSICAL_MEMORY) && !defined(CS_SOUND_FIXTURE)
            std::fprintf(stderr,"AUDIO at clock %llu: arbiter blocked by texq total=%llu longest=%llu (at %llu, occupancy %u); texq occupancy now %u, current run %llu; spu state=%u\n",(unsigned long long)clock,(unsigned long long)stall_total,(unsigned long long)stall_max,(unsigned long long)stall_max_at,stall_max_occ,unsigned(CS_PROBE(texq__DOT__wr_ptr)-CS_PROBE(texq__DOT__rd_ptr))&0x1fff,(unsigned long long)stall_run,unsigned(CS_PROBE(spu__DOT__state)));
#endif
            std::fprintf(stderr,"FAIL audio fault=%u underrun=%u modes=%02x reverb=%u\n",dut.audio_fault,dut.audio_underrun,dut.audio_unsupported_modes,dut.audio_unsupported_reverb);return 1;}
        if(dut.dma_fault && !stopped_device){std::fprintf(stderr,"FAIL DMA address=%08x\n",dut.dma_fault_address);return 1;}
        if(dut.gpu_fault){std::fprintf(stderr,"FAIL GPU address=%08x after %u packets / %u pixels\n",dut.gpu_fault_address,dut.gpu_packets,dut.gpu_pixels);return 1;}
#ifdef CS_SOUND_FIXTURE
        if(sound_outputs>=24){
            auto ram_word=[&](unsigned a){uint32_t v=0;for(unsigned i=0;i<4;++i)v|=uint32_t(memory.ram.at(a+i))<<(8*i);return v;};
            if(ram_word(0x718)!=0x5a5aa5a5||ram_word(0x71c)!=0x12345678||ram_word(0x720)!=0xcafebeef||ram_word(0x724)!=0x5a5aa5a5||cabinet_reads!=2||ram_word(0x710)!=0xffffffff||ram_word(0x714)!=0xffffff7f||!dut.cache_enabled||!dut.cache_hits||!dut.cache_misses||control_transactions!=2||ram_word(0x70c)!=0x80a04b01||!(client_requests[4]||frame_burst_reads)||!dut.video_words||dut.sp!=0x021ff000||!(dut.sr&0x2000)||dut.retire_opcode!=0xdeff||irq_acks!=2||ram_word(0x700)!=2||ram_word(0x704)!=4||ram_word(0x708)!=0x80000000||!audio_nonzero||!sound_mmios||!client_requests[3]){std::fprintf(stderr,"FAIL diagnostic IRQ/sound acceptance: scan words=%llu bursts=%llu line words=%u sp=%08x sr=%08x opcode=%04x cabinet=%u control=%llu status70c=%08x cache=%u/%u/%u snapshots=%08x/%08x/%08x/%08x/%08x/%08x; acks=%u counter=%u status=%08x pending=%08x nonzero=%llu MMIO=%llu reads=%llu\n",(unsigned long long)client_requests[4],(unsigned long long)frame_burst_reads,dut.video_words,dut.sp,dut.sr,dut.retire_opcode,cabinet_reads,(unsigned long long)control_transactions,ram_word(0x70c),dut.cache_enabled,dut.cache_hits,dut.cache_misses,ram_word(0x710),ram_word(0x714),ram_word(0x718),ram_word(0x71c),ram_word(0x720),ram_word(0x724),irq_acks,ram_word(0x700),ram_word(0x704),ram_word(0x708),(unsigned long long)audio_nonzero,(unsigned long long)sound_mmios,(unsigned long long)client_requests[3]);return 1;}
            std::printf("PASS CPU-driven sound BIOS: %u matched instructions, %llu sound MMIO, %llu SPU reads, %u checked active-period outputs, %u IRQ2 entries/returns, low/high channel ends acknowledged, no audio deadline/error. Diagnostic BIOS only; no game boot claim.\n",instructions,(unsigned long long)sound_mmios,(unsigned long long)client_requests[3],sound_outputs,irq_acks);std::printf("CP0 integrated cache: %llu transfers, %u hits, %u misses, CPU-stored status=%08x\n",(unsigned long long)control_transactions,dut.cache_hits,dut.cache_misses,ram_word(0x70c));std::printf("CABINET uncached CPU reads: %u, stored DIP snapshots=%08x/%08x with cache enabled\n",cabinet_reads,ram_word(0x710),ram_word(0x714));std::printf("RAM mirrored CPU cache snapshots: %08x/%08x/%08x, writes visible through both 020/028 views\n",ram_word(0x71c),ram_word(0x720),ram_word(0x724));std::printf("SCANOUT integrated traffic: %llu word reads, %llu frame line-burst reads, %u line-buffer words, no video fault/underrun\n",(unsigned long long)client_requests[4],(unsigned long long)frame_burst_reads,dut.video_words);return 0;
        }
#endif

#ifndef CS_SOUND_FIXTURE
        if(cpu_stats.enabled()){
            cpu_stats.bus(clock,accepted,client,responded);
            cpu_stats.sample(CS_PROBE(cpu__DOT__state),CS_PROBE(cpu__DOT__continuation),CS_PROBE(cp0__DOT__state),
                dut.retire,false,false,clock&1);
            cpu_stats.window_report(clock,dut.pc,dut.gpu_packets);
        }
#if defined(CS_PHYSICAL_MEMORY)
        // CS_PERF=<window clocks>: game-rate profile. Per window: raster frames, display-bank flips
        // (game frames shown), GPU non-idle clocks, retired instructions and those retired in the
        // flip-wait idle range CS_PERF_IDLE=lo-hi (hex PCs), arbiter clocks blocked downstream.
        // Written line by line to CS_PERF_FILE (default stdout). Observation only.
        {static const uint64_t perf_window=std::getenv("CS_PERF")?std::stoull(std::getenv("CS_PERF")):0;
         if(perf_window){
            static FILE* perf_out=std::getenv("CS_PERF_FILE")?std::fopen(std::getenv("CS_PERF_FILE"),"w"):stdout;
            static std::vector<std::pair<uint32_t,uint32_t>> idle_ranges;static bool idle_init=false;
            if(!idle_init){idle_init=true;if(const char* r=std::getenv("CS_PERF_IDLE")){unsigned lo,hi;int used;
                    while(std::sscanf(r,"%x-%x%n",&lo,&hi,&used)==2){idle_ranges.emplace_back(lo,hi);r+=used;if(*r==',')++r;else break;}}
                std::fprintf(perf_out,"PERF clock,frames,flips,gpu_busy_pct,instr,idle_instr,busy_instr,busy_instr_per_frame,clk_per_instr,arb_blocked_pct,texq_max_occ,pc\n");}
            static uint64_t w_clocks=0,w_gpu=0,w_ret=0,w_idle=0,w_blk=0,w_flips=0,frames0=0;static unsigned w_occ=0,last_bank=0;
            ++w_clocks;
            if(CS_PROBE(gpu__DOT__state)!=0)++w_gpu;
            if(dut.retire){++w_ret;for(auto& r:idle_ranges)if(dut.retire_pc>=r.first&&dut.retire_pc<=r.second){++w_idle;break;}}
            if(CS_PROBE(a_valid)&&!CS_PROBE(a_ready))++w_blk;
            const unsigned occ=unsigned(CS_PROBE(texq__DOT__wr_ptr)-CS_PROBE(texq__DOT__rd_ptr))&0x1fff;if(occ>w_occ)w_occ=occ;
            const unsigned bank=unsigned(CS_PROBE(gpu__DOT__display_bank));if(bank!=last_bank){++w_flips;last_bank=bank;}
            if(w_clocks>=perf_window){
                const uint64_t frames=observer.raster_frames-frames0,busy=w_ret-w_idle;
                std::fprintf(perf_out,"PERF %llu,%llu,%llu,%.1f,%llu,%llu,%llu,%.0f,%.2f,%.1f,%u,%08x\n",(unsigned long long)clock,
                    (unsigned long long)frames,(unsigned long long)w_flips,100.0*w_gpu/w_clocks,(unsigned long long)w_ret,(unsigned long long)w_idle,
                    (unsigned long long)busy,frames?double(busy)/frames:0.0,double(w_clocks)/std::max<uint64_t>(w_ret,1),
                    100.0*w_blk/w_clocks,w_occ,unsigned(dut.pc));
                std::fflush(perf_out);
                frames0=observer.raster_frames;w_clocks=w_gpu=w_ret=w_idle=w_blk=w_flips=0;w_occ=0;
            }
         }}
        // CS_AUTOPLAY=<coin frame>: coin 1 (SYSTEM bit 4) for 14 raster frames, 1P start (bit 0) 200 frames later,
        // then P1 button 1 (P1_P2 bit 0) toggled every 8 frames from 700 frames after the coin (topbladv MAME
        // script timing relative to the coin). Physical pins only, like the live cabinet commands.
        {static const uint64_t coin_frame=std::getenv("CS_AUTOPLAY")?std::stoull(std::getenv("CS_AUTOPLAY")):0;
         if(coin_frame){const uint64_t f=observer.raster_frames;
            uint8_t sys=0xff;if(f>=coin_frame&&f<coin_frame+14)sys&=~0x10;if(f>=coin_frame+200&&f<coin_frame+214)sys&=~0x01;
            dut.system_n=sys;dut.p1_p2_n=(f>=coin_frame+700&&((f/8)&1)==0)?0xfffffffeu:0xffffffffu;}}
#endif
        observer.observe();
#ifdef CS_CHECKPOINT
        const uint64_t completed_clock=clock+1;
        const bool checkpoint_due=(next_checkpoint&&completed_clock>=next_checkpoint)||(checkpoint_end&&completed_clock>=checkpoint_end);
#ifdef CS_TIMED_SDRAM
        const bool checkpoint_allowed=!checkpoint_pending_dq||!sdram_pins.returns.empty();
#else
        const bool checkpoint_allowed=true;
#endif
        if(checkpoint_due&&checkpoint_allowed){
            save_checkpoint(observer.ROOT+"/checkpoints/"+std::to_string(completed_clock),completed_clock,dut,external_state);
#ifdef CS_TIMED_SDRAM
            std::printf("TIMED_CHECKPOINT profile=%s pin_cycles=%llu pending_dq=%zu\n",sdram_pins.profile.name.c_str(),(unsigned long long)sdram_pins.cycles,sdram_pins.returns.size());
#endif
            next_checkpoint=checkpoint_period?completed_clock+checkpoint_period:0;
            if(checkpoint_end&&completed_clock>=checkpoint_end){observer.reason="checkpoint_probe";return 0;}
        }
#endif
        if(stop_packets && observer.active_packet_completed && dut.gpu_packets>=stop_packets){
            observer.reason="packet_probe";
            std::printf("PROBE original cold boot reached a completed drawing packet: %u matched instructions / %llu clocks, %u GPU packets / %u pixel stores. Natural activity and RAM snapshots saved privately; no attract/gameplay acceptance claim.\n",
                        instructions,(unsigned long long)clock,dut.gpu_packets,dut.gpu_pixels);
            return 0;
        }
#endif
        if(dut.fault || dut.dma_fault){
            std::printf("CP0 observed transfers=%llu cache enabled=%u hits=%u misses=%u invalidations=%u; descriptor/revision qualified\n",
                (unsigned long long)control_transactions,dut.cache_enabled,dut.cache_hits,dut.cache_misses,dut.cache_invalidations);

            std::printf("BOARD integrated bus CPU/DMA/GPU/SPU reads=%llu/%llu/%llu/%llu sound MMIO=%llu audio samples=%llu nonzero=%llu; audio faults/deadlines clear\n",(unsigned long long)client_requests[0],(unsigned long long)client_requests[1],(unsigned long long)client_requests[2],(unsigned long long)client_requests[3],(unsigned long long)sound_mmios,(unsigned long long)audio_samples,(unsigned long long)audio_nonzero);
            if(!stopped_device){
                std::fprintf(stderr,"FAIL unresolved CPU instruction PC=%08x opcode=%04x after %u instructions / %llu clocks; SR=%08x SP=%08x ER=%08x GPU=%u packets/%u pixels\n",dut.fault_pc,dut.fault_opcode,instructions,(unsigned long long)clock,dut.sr,dut.sp,dut.er,dut.gpu_packets,dut.gpu_pixels);
                for(unsigned i=0;i<8;i++)std::fprintf(stderr,"R%u=%08x ",i,dut.registers[i]);std::fprintf(stderr,"\n");
                const unsigned count=std::min<unsigned>(instructions,tail.size());for(unsigned i=instructions-count;i<instructions;++i)std::fprintf(stderr,"%08x %04x\n",tail[i%tail.size()].first,tail[i%tail.size()].second);
                if(dut.fault_pc>=0x02000000&&dut.fault_pc<0x02800000){unsigned offset=(dut.fault_pc&0x7fffff)&~255u;std::ofstream context("sim/obj_dir/boot_probe/fault_code.bin",std::ios::binary);context.write(reinterpret_cast<const char*>(memory.ram.data()+offset),512);}
                return 1;
            }
            std::printf("PROBE BIOS cold boot: %u RTL instructions match independent MAME CPU with observed memory/MMIO inputs; %u memory requests / %u RTL MMIO accesses / %llu system clocks. Stopped at pending device target=%u address=%08x instruction=%08x opcode=%04x. No full-board/attract/gameplay claim.\n",instructions,requests,mmios,(unsigned long long)clock,stop_target,stop_address,dut.fault_pc,dut.fault_opcode);
            const unsigned count=std::min<unsigned>(instructions,tail.size());for(unsigned i=instructions-count;i<instructions;++i)std::printf("%08x %04x\n",tail[i%tail.size()].first,tail[i%tail.size()].second);
            return 0;
        }
    }
    std::printf("CP0 observed transfers=%llu cache enabled=%u hits=%u misses=%u invalidations=%u; descriptor/revision qualified\n",
        (unsigned long long)control_transactions,dut.cache_enabled,dut.cache_hits,dut.cache_misses,dut.cache_invalidations);
#ifndef CS_SOUND_FIXTURE
    observer.reason="clock_limit";
#endif
#ifndef CS_SOUND_FIXTURE
    std::fprintf(stderr,"GPU state=%u flip_count=%u flip_sync=%u uses_sync=%u front=%u rear=%u control=%02x display_bank=%u%c",unsigned(CS_PROBE(gpu__DOT__state)),unsigned(CS_PROBE(gpu__DOT__flip_count)),unsigned(CS_PROBE(gpu__DOT__flip_sync)),unsigned(CS_PROBE(gpu__DOT__uses_sync_flip)),unsigned(CS_PROBE(gpu__DOT__queue_front)),unsigned(CS_PROBE(gpu__DOT__queue_rear)),unsigned(CS_PROBE(gpu__DOT__control)),unsigned(CS_PROBE(gpu__DOT__display_bank)),10);
#endif
    std::fprintf(stderr,"ARBITER blocked by texq: total=%llu clocks, longest run=%llu clocks at clock %llu (queue occupancy then %u)\n",(unsigned long long)stall_total,(unsigned long long)stall_max,(unsigned long long)stall_max_at,stall_max_occ);
    std::fprintf(stderr,"TEXTURE writes=%llu of which while earlier packets pending=%llu, renderer reads of lines written after their packet was submitted (races)=%llu\n",(unsigned long long)texture_writes,(unsigned long long)texture_writes_pending,(unsigned long long)texture_races);
    std::fprintf(stderr,"FAIL probe timeout after %u instructions / %llu clocks: PC=%08x SR=%08x SP=%08x ER=%08x memory=%08x MMIO=%08x requests=%u mmios=%u GPU packets=%u pixels=%u\n",instructions,(unsigned long long)max_clocks,dut.pc,dut.sr,dut.sp,dut.er,last_memory,last_mmio,requests,mmios,dut.gpu_packets,dut.gpu_pixels);
    for(unsigned i=0;i<8;i++)std::fprintf(stderr,"R%u=%08x ",i,dut.registers[i]);
    std::fprintf(stderr,"\n");
    const unsigned count=std::min<unsigned>(instructions,tail.size());for(unsigned i=instructions-count;i<instructions;++i)std::fprintf(stderr,"%08x %04x\n",tail[i%tail.size()].first,tail[i%tail.size()].second);
    return 1;
}
