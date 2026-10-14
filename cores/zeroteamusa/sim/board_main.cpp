#ifdef FULL_VIDEO
#include "Vzero_av_top.h"
using BoardModel=Vzero_av_top;
#else
#include "Vzero_board_top.h"
using BoardModel=Vzero_board_top;
#endif
#include "verilated.h"
#ifdef FULL_VIDEO
#include "verilated_save.h"
#endif
#include <fstream>
#include <iostream>
#include <vector>
#include <map>
#include <cstdint>
#include <stdexcept>
#include <array>
#include <string>
#include <sstream>
#include <algorithm>

#ifdef FULL_VIDEO
// This is external ROM-bridge/capture state, not an emulated CPU or device.
// Actual registers and memories live in the serialized Verilator model.
struct HostState {
    uint64_t requests,cop_requests,writes,reads,irqs,dma,pal_dma,busy,main_due,cop_due;
    uint64_t gfx_due,gfx_requests,av_frame_pixels,av_complete_frames;
    uint64_t zfetch,ziack,zwrite,zcoinread,zfmwrite,zokiwrite,asamples,anonzero,zpendingcycles,soundtraces;
    uint32_t main_address,cop_address,gfx_address;
    uint8_t gfx_kind;
    bool main_pending,cop_pending,main_token,cop_previous;
    bool previous_read,previous_write,previous_irq,previous_dma,previous_pal;
    bool gfx_pending,gfx_previous,zpf,zpi,zpw,zpr;
    // Dedicated sprite row port (added with the multi-word SDRAM sprite path).
    uint64_t spr_due; uint32_t spr_address; bool spr_pending,spr_previous;
};
struct InputEvent {
    uint64_t cycle;
    uint8_t p1,p2,p3,p4,coin;
    uint16_t dips,system;
};
static std::vector<InputEvent> load_events(const std::string& path) {
    std::vector<InputEvent> events;
    if(path.empty())return events;
    std::ifstream f(path);
    if(!f)throw std::runtime_error("Missing input schedule");
    std::string line;
    std::getline(f,line);
    if(line!="cycle,p1,p2,p3,p4,coin,dips,system")throw std::runtime_error("Wrong input CSV header");
    while(std::getline(f,line)) {
        if(line.empty())continue;
        std::replace(line.begin(),line.end(),',',' ');
        std::istringstream row(line);std::array<std::string,8> fields;
        for(auto& x:fields)if(!(row>>x))throw std::runtime_error("Incomplete input event");
        std::array<uint64_t,8> v;
        for(size_t i=0;i<v.size();++i)v[i]=std::stoull(fields[i],nullptr,0);
        for(size_t i=1;i<=5;++i)if(v[i]>255)throw std::runtime_error("Input byte overflow");
        if(v[6]>65535||v[7]>65535)throw std::runtime_error("Input word overflow");
        if(!events.empty()&&v[0]<=events.back().cycle)throw std::runtime_error("Unordered input schedule");
        events.push_back({v[0],uint8_t(v[1]),uint8_t(v[2]),uint8_t(v[3]),uint8_t(v[4]),uint8_t(v[5]),uint16_t(v[6]),uint16_t(v[7])});
    }
    return events;
}
#endif

static uint16_t word(const std::vector<uint8_t>& rom, uint32_t a) {
    a &= ~1u;
    if (a + 1 >= rom.size()) throw std::runtime_error("ROM address outside region");
    return rom[a] | (rom[a+1] << 8);
}
// Optional ROM latency jitter (ZERO_ROM_JITTER=N): response delay = 3 + uniform[0..N] clocks,
// to expose CPU/COP sensitivity to the variable SDRAM latency seen on hardware.
static bool main_seen=false;
static unsigned rom_jitter_max=0;
// ZERO_ROM_LATENCY=N: fixed main/COP ROM response delay (default 3). The
// production SDRAM path answers a main fetch in ~10 clocks unloaded.
static unsigned rom_latency=3;
static std::vector<uint64_t> write_milestones;
static uint32_t rom_jitter_state=0x2545F491u;
static unsigned rom_jitter() {
    if(!rom_jitter_max)return 0;
    rom_jitter_state^=rom_jitter_state<<13;rom_jitter_state^=rom_jitter_state>>17;rom_jitter_state^=rom_jitter_state<<5;
    return rom_jitter_state%(rom_jitter_max+1);
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if(const char* j=std::getenv("ZERO_ROM_JITTER"))rom_jitter_max=std::stoul(j);
    if(const char* l=std::getenv("ZERO_ROM_LATENCY"))rom_latency=std::stoul(l);
    // ZERO_RAM_TRACE=path: at every IRQ acknowledge append {u32 irq index, 64K
    // LE words of work RAM 0x00000-0x1ffff} read through the combinational probe
    // (no clock), for frame-by-frame comparison against MAME.
    std::ofstream ram_trace;
    if(const char* t=std::getenv("ZERO_RAM_TRACE"))ram_trace.open(t,std::ios::binary);
    std::vector<uint8_t> ram_frame(2*65536);
    uint64_t cycles = argc > 1 ? std::stoull(argv[1]) : 10000000;
#ifdef FULL_VIDEO
    std::string resume_path,input_path,run_tag;
    uint64_t snapshot_period=104000000;
    for(int i=2;i<argc;++i) {
        std::string option=argv[i];
        if(++i>=argc)throw std::runtime_error("Missing option value");
        if(option=="--load")resume_path=argv[i];
        else if(option=="--inputs")input_path=argv[i];
        else if(option=="--tag")run_tag=argv[i];
        else if(option=="--checkpoint-every")snapshot_period=std::stoull(argv[i]);
        else throw std::runtime_error("Unknown AV option");
    }
    if(run_tag.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")!=std::string::npos)
        throw std::runtime_error("Invalid run tag");
    auto events=load_events(input_path);size_t next_event=0;
    std::ifstream stamp_input("sim/results/av-source-stamp.json",std::ios::binary);
    if(!stamp_input)throw std::runtime_error("Missing actual build-input stamp");
    const std::string run_source_stamp((std::istreambuf_iterator<char>(stamp_input)),{});
    auto apply_inputs=[&](BoardModel& t,const InputEvent& e) {
        t.p1=e.p1;t.p2=e.p2;t.p3=e.p3;t.p4=e.p4;t.coin_input=e.coin;t.dips=e.dips;t.system_input=e.system;
    };
#endif
    std::ifstream input("roms/regions/maincpu.bin", std::ios::binary);
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(input)), {});
    if (rom.size() != 0x100000) throw std::runtime_error("Expected exact US program region");
    BoardModel top;
#ifdef FULL_VIDEO
    auto load_gfx=[](const char* name) {
        std::ifstream f(std::string("roms/regions/")+name+".bin",std::ios::binary);
        if(!f)throw std::runtime_error("Missing graphics ROM region");
        return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),{});
    };
    auto chars=load_gfx("chars"),tiles=load_gfx("tiles"),sprites=load_gfx("sprites");
    auto soundrom=load_gfx("audiocpu"),oki=load_gfx("oki");
    if(soundrom.size()!=0x20000 || oki.size()!=0x100000)throw std::runtime_error("Wrong sound ROM size");
    uint64_t zfetch=0,ziack=0,zwrite=0,zcoinread=0,zfmwrite=0,zokiwrite=0,asamples=0,anonzero=0,zpendingcycles=0;
    bool zpf=false,zpi=false,zpw=false,zpr=false;
    std::ofstream pcm("sim/results/audio-live"+run_tag+".pcm",std::ios::binary);
    std::ofstream soundtrace("sim/results/audio-live"+run_tag+"-trace.csv");soundtrace<<"cycle,address,data\n";
    uint64_t soundtraces=0;
    bool gfx_pending=false,gfx_previous=false;
    uint64_t gfx_due=0,gfx_requests=0,av_frame_pixels=0,av_complete_frames=0;
    uint32_t gfx_address=0; uint8_t gfx_kind=0;
    bool spr_pending=false,spr_previous=false; uint64_t spr_due=0; uint32_t spr_address=0;
    std::vector<uint8_t> av_image(320*256*3),av_completed(320*256*3);
    top.av_rom_data=0; top.av_rom_valid=0;
    const std::string dump_prefix="sim/results/board-av"+run_tag+"-";
#else
    const std::string dump_prefix="sim/results/board-";
#endif
    top.p1=top.p2=top.p3=top.p4=255;
    top.dips=65535; top.system_input=65535;
    top.rom_ack=0; top.rom_data=65535; top.cop_rom_ack=0; top.cop_rom_data=65535;
    top.video_probe_address=0; top.ram_probe_address=0; top.pause=0;
#ifdef FULL_VIDEO
    top.coin_input=255;top.oki_rom_data=0;top.oki_rom_ok=0;
    top.reset=1;top.audio_download=1;top.audio_download_wr=1;
    for(uint32_t a=0;a<0x10000;a+=2) {
        uint32_t source=a<0x8000?a:a+0x8000;
        top.audio_download_addr=0xa0000+a;
        top.audio_download_data=soundrom[source]|(soundrom[source+1]<<8);
        top.clk=0;top.eval();top.clk=1;top.eval();
    }
    top.audio_download=top.audio_download_wr=0;
#endif
    uint64_t requests=0, cop_requests=0, writes=0, reads=0, irqs=0, dma=0, pal_dma=0, busy=0;
    uint64_t main_due=0, cop_due=0;
    bool main_pending=false, cop_pending=false, main_token=false, cop_previous=false;
    bool previous_read=false, previous_write=false, previous_irq=false, previous_dma=false, previous_pal=false;
    uint32_t main_address=0, cop_address=0;
    std::map<uint32_t,uint64_t> device_writes;
    uint64_t start_cycle=0;
#ifdef FULL_VIDEO
    auto save_checkpoint=[&](uint64_t next_cycle) {
        const std::string base="sim/results/av"+run_tag+"-checkpoint-"+std::to_string(next_cycle);
        VerilatedSave rtl;rtl.open((base+".rtl").c_str());rtl<<next_cycle;rtl<<top;rtl.close();
        HostState h{requests,cop_requests,writes,reads,irqs,dma,pal_dma,busy,main_due,cop_due,
            gfx_due,gfx_requests,av_frame_pixels,av_complete_frames,zfetch,ziack,zwrite,zcoinread,zfmwrite,zokiwrite,
            asamples,anonzero,zpendingcycles,soundtraces,main_address,cop_address,gfx_address,gfx_kind,
            main_pending,cop_pending,main_token,cop_previous,previous_read,previous_write,previous_irq,previous_dma,
            previous_pal,gfx_pending,gfx_previous,zpf,zpi,zpw,zpr,
            spr_due,spr_address,spr_pending,spr_previous};
        std::ofstream host(base+".host",std::ios::binary);
        uint64_t magic=0x5a54484f53543031ULL,size=sizeof(h),n=device_writes.size();
        host.write(reinterpret_cast<char*>(&magic),8);host.write(reinterpret_cast<char*>(&size),8);
        host.write(reinterpret_cast<char*>(&h),sizeof(h));
        host.write(reinterpret_cast<char*>(av_image.data()),av_image.size());
        host.write(reinterpret_cast<char*>(av_completed.data()),av_completed.size());
        host.write(reinterpret_cast<char*>(&n),8);
        for(auto [a,count]:device_writes){host.write(reinterpret_cast<const char*>(&a),4);host.write(reinterpret_cast<const char*>(&count),8);}
        std::ofstream copied(base+".json",std::ios::binary);copied<<run_source_stamp;
        std::cout<<"Saved full RTL/bridge checkpoint "<<base<<std::endl;
    };
    if(!resume_path.empty()) {
        VerilatedRestore rtl;rtl.open((resume_path+".rtl").c_str());rtl>>start_cycle;rtl>>top;rtl.close();
        std::ifstream host(resume_path+".host",std::ios::binary);
        HostState h{};uint64_t magic=0,size=0,n=0;
        host.read(reinterpret_cast<char*>(&magic),8);host.read(reinterpret_cast<char*>(&size),8);
        if(magic!=0x5a54484f53543031ULL||size!=sizeof(h))throw std::runtime_error("Wrong checkpoint bridge format");
        host.read(reinterpret_cast<char*>(&h),sizeof(h));
        host.read(reinterpret_cast<char*>(av_image.data()),av_image.size());
        host.read(reinterpret_cast<char*>(av_completed.data()),av_completed.size());
        host.read(reinterpret_cast<char*>(&n),8);
        if(n>0x100000)throw std::runtime_error("Corrupt checkpoint counter map");
        for(uint64_t i=0;i<n;++i){uint32_t a;uint64_t count;host.read(reinterpret_cast<char*>(&a),4);host.read(reinterpret_cast<char*>(&count),8);device_writes[a]=count;}
        if(!host)throw std::runtime_error("Truncated checkpoint bridge state");
        requests=h.requests;cop_requests=h.cop_requests;writes=h.writes;reads=h.reads;irqs=h.irqs;dma=h.dma;
        pal_dma=h.pal_dma;busy=h.busy;main_due=h.main_due;cop_due=h.cop_due;gfx_due=h.gfx_due;
        gfx_requests=h.gfx_requests;av_frame_pixels=h.av_frame_pixels;av_complete_frames=h.av_complete_frames;
        zfetch=h.zfetch;ziack=h.ziack;zwrite=h.zwrite;zcoinread=h.zcoinread;zfmwrite=h.zfmwrite;zokiwrite=h.zokiwrite;
        asamples=h.asamples;anonzero=h.anonzero;zpendingcycles=h.zpendingcycles;soundtraces=h.soundtraces;
        main_address=h.main_address;cop_address=h.cop_address;gfx_address=h.gfx_address;gfx_kind=h.gfx_kind;
        main_pending=h.main_pending;cop_pending=h.cop_pending;main_token=h.main_token;cop_previous=h.cop_previous;
        previous_read=h.previous_read;previous_write=h.previous_write;previous_irq=h.previous_irq;previous_dma=h.previous_dma;previous_pal=h.previous_pal;
        gfx_pending=h.gfx_pending;gfx_previous=h.gfx_previous;zpf=h.zpf;zpi=h.zpi;zpw=h.zpw;zpr=h.zpr;
        spr_due=h.spr_due;spr_address=h.spr_address;spr_pending=h.spr_pending;spr_previous=h.spr_previous;
        while(next_event<events.size()&&events[next_event].cycle<start_cycle)apply_inputs(top,events[next_event++]);
        std::cout<<"Restored actual RTL checkpoint at cycle "<<start_cycle<<std::endl;
    }
#endif
    for (uint64_t c=start_cycle; c<cycles && !Verilated::gotFinish(); ++c) {
#ifdef FULL_VIDEO
        while(next_event<events.size()&&events[next_event].cycle==c)apply_inputs(top,events[next_event++]);
#endif
        top.reset=c<60;
        top.vblank=c>=60 && ((c-60) % (512*282*12)) >= (512*256*12);
        top.clk=0; top.eval();
        // Level request, one-clock acknowledge pulse: same contract as hardware.
        top.rom_ack=0;
        if(!top.rom_request)main_seen=false;
        if (!top.reset && !main_pending && top.rom_request && !main_seen) {
            main_pending=true; main_seen=true; main_due=c+rom_latency+rom_jitter(); main_address=top.rom_address;
            ++requests;
        }
        if (main_pending && c==main_due) {
            top.rom_data=word(rom,main_address); top.rom_ack=1; main_pending=false;
        }
        top.cop_rom_ack=0;
        if (!top.reset && top.cop_rom_request && !cop_previous) {
            if (cop_pending) throw std::runtime_error("Overlapping COP ROM request");
            cop_pending=true; cop_due=c+rom_latency+rom_jitter(); cop_address=top.cop_rom_address; ++cop_requests;
        }
        if (cop_pending && c==cop_due) {
            top.cop_rom_data=word(rom,cop_address); top.cop_rom_ack=1; cop_pending=false;
        }
        cop_previous=top.cop_rom_request;
#ifdef FULL_VIDEO
        top.oki_rom_data=oki.at(top.oki_rom_address);top.oki_rom_ok=1;
        top.av_rom_valid=0;
        if(!top.reset && top.av_rom_request && !gfx_previous) {
            if(gfx_pending)throw std::runtime_error("Overlapping graphics ROM request");
            gfx_pending=true; gfx_due=c+3+rom_jitter(); gfx_address=top.av_rom_address;
            gfx_kind=top.av_rom_kind; ++gfx_requests;
        }
        gfx_previous=top.av_rom_request;
        // Sprite row port: two native LE32 halves, the second two clocks later.
        top.av_sprite_valid=0;
        if(!top.reset && top.av_sprite_request && !spr_previous) {
            if(spr_pending)throw std::runtime_error("Overlapping sprite ROM request");
            spr_pending=true; spr_due=c+3+rom_jitter(); spr_address=top.av_sprite_address; ++gfx_requests;
        }
        spr_previous=top.av_sprite_request;
        if(spr_pending && (c==spr_due || c==spr_due+2)) {
            uint32_t o=spr_address+(c==spr_due?0:4);
            if(o+3>=sprites.size())throw std::runtime_error("Sprite region overflow");
            top.av_sprite_data=sprites[o]|(uint32_t(sprites[o+1])<<8)|(uint32_t(sprites[o+2])<<16)|(uint32_t(sprites[o+3])<<24);
            top.av_sprite_half=c!=spr_due; top.av_sprite_valid=top.av_sprite_request;
            if(c==spr_due+2) spr_pending=false;
        }
        if(gfx_pending && c==gfx_due) {
            const auto& bytes=gfx_kind==4?chars:(gfx_kind==3?sprites:tiles);
            if(gfx_address+3>=bytes.size())throw std::runtime_error("Graphics region overflow");
            uint32_t first=bytes[gfx_address]|(uint32_t(bytes[gfx_address+1])<<8);
            uint32_t second=bytes[gfx_address+2]|(uint32_t(bytes[gfx_address+3])<<8);
            top.av_rom_data=gfx_kind==3?(first|(second<<16)):((first<<16)|second);
            top.av_rom_valid=1; gfx_pending=false;
        }
#endif
        top.eval();
        if (!top.reset) {
            if (top.cpu_read && !previous_read) ++reads;
            if (top.cpu_write && !previous_write) {
                ++writes;
                if(writes%10000==0) write_milestones.push_back(c);
                if (top.cpu_address>=0x400 && top.cpu_address<0x800) ++device_writes[top.cpu_address];
            }
            if (top.irq_ack && !previous_irq) {
                ++irqs;
                if(ram_trace.is_open()) {
                    const uint16_t keep=top.ram_probe_address;
                    for(uint32_t a=0;a<65536;++a) {
                        top.ram_probe_address=a; top.eval();
                        ram_frame[2*a]=uint8_t(top.ram_probe_data); ram_frame[2*a+1]=uint8_t(top.ram_probe_data>>8);
                    }
                    top.ram_probe_address=keep; top.eval();
                    const uint32_t n=uint32_t(irqs);
                    ram_trace.write(reinterpret_cast<const char*>(&n),4);
                    ram_trace.write(reinterpret_cast<const char*>(ram_frame.data()),ram_frame.size());
                    ram_trace.flush();
                }
            }
            if (top.video_dma_write && !previous_dma) ++dma;
            if (top.palette_dma_write && !previous_pal) ++pal_dma;
            busy += top.cop_busy;
        }
        previous_read=top.cpu_read; previous_write=top.cpu_write; previous_irq=top.irq_ack;
        previous_dma=top.video_dma_write; previous_pal=top.palette_dma_write;
#ifdef FULL_VIDEO
        if(!top.reset) {
            zfetch+=top.sound_fetch&&!zpf;ziack+=top.sound_iack&&!zpi;
            zcoinread+=top.sound_read&&!zpr&&top.sound_address==0x4013;
            if(top.sound_write&&!zpw) {
                ++zwrite;zfmwrite+=top.sound_address==0x4009;zokiwrite+=top.sound_address==0x6000;
                if(top.sound_address>=0x4000 && soundtraces++<4000)
                    soundtrace<<c<<","<<top.sound_address<<","<<int(top.sound_data)<<"\n";
            }
            zpendingcycles+=top.sound_pending;
        }
        zpf=top.sound_fetch;zpi=top.sound_iack;zpw=top.sound_write;zpr=top.sound_read;
#endif
        top.clk=1; top.eval();
#ifdef FULL_VIDEO
        if(!top.reset&&top.audio_sample) {
            ++asamples;anonzero+=top.audio_l!=0;
            uint8_t b[2]={uint8_t(top.audio_l),uint8_t(top.audio_l>>8)};
            pcm.write(reinterpret_cast<char*>(b),2);
        }
        if(!top.reset && top.av_pixel_strobe && top.av_pixel_display) {
            if(top.av_pixel_x==0 && top.av_pixel_y==0) {
                if(av_frame_pixels==320*256) { av_completed=av_image; ++av_complete_frames; }
                av_frame_pixels=0;
            }
            size_t i=(top.av_pixel_y*320+top.av_pixel_x)*3;
            if(i+2>=av_image.size())throw std::runtime_error("Video output coordinate overflow");
            av_image[i]=top.av_r; av_image[i+1]=top.av_g; av_image[i+2]=top.av_b; ++av_frame_pixels;
        }
        if(c && c%104000000==0) {
            std::cout<<"AV checkpoint cycles="<<c<<" frames="<<av_complete_frames<<" IRQ="<<irqs
                     <<" Z80fetch="<<zfetch<<" soundIRQ="<<ziack<<" FMwrites="<<zfmwrite
                     <<" OKIwrites="<<zokiwrite<<" samples="<<asamples<<" nonzero="<<anonzero<<std::endl;
            std::ofstream frame("sim/results/rtl-live"+(run_tag.empty()?std::string():"-"+run_tag)+"-checkpoint-"+std::to_string(c/104000000)+".ppm",std::ios::binary);
            frame<<"P6\n320 256\n255\n";frame.write(reinterpret_cast<char*>(av_completed.data()),av_completed.size());
        }
        if(snapshot_period && (c+1)%snapshot_period==0)save_checkpoint(c+1);
#endif
    }
    // Let already-issued board operations settle, then save the real RTL buffers.
    top.pause=1;
    for (int i=0;i<64;++i) { top.clk=0; top.eval(); top.clk=1; top.eval(); }
    const std::array<const char*,7> names={"bg","fg","mg","text","palette","sprite","workram"};
    std::array<std::ofstream,7> dumps;
    std::array<uint64_t,7> nonzero{};
    for(size_t i=0;i<names.size();++i) dumps[i].open(dump_prefix+names[i]+".bin",std::ios::binary);
    for(uint32_t a=0;a<65536;++a) {
        top.video_probe_address=a&2047; top.ram_probe_address=a;
        for(int i=0;i<2;++i) { top.clk=0; top.eval(); top.clk=1; top.eval(); }
        std::array<uint16_t,7> data={top.bg_data,top.fg_data,top.mg_data,top.text_data,top.palette_data,top.sprite_data,top.ram_probe_data};
        for(size_t i=0;i<data.size();++i) {
            if(i<6 && a>=2048) continue;
            uint8_t bytes[2]={uint8_t(data[i]),uint8_t(data[i]>>8)};
            dumps[i].write(reinterpret_cast<char*>(bytes),2); nonzero[i]+=data[i]!=0;
        }
    }
    top.final();
    std::ofstream report(dump_prefix+"boot.json");
    report << "{\n  \"scope\": \"real V30/COP/CRTC/memory with target AV when enabled\",\n"
      << "  \"cycles\": "<<cycles<<",\n  \"rom_requests\": "<<requests
      <<",\n  \"cop_rom_requests\": "<<cop_requests<<",\n  \"cpu_reads\": "<<reads
      <<",\n  \"cpu_writes\": "<<writes<<",\n  \"irq_acks\": "<<irqs
      <<",\n  \"video_dma_words\": "<<dma<<",\n  \"palette_dma_words\": "<<pal_dma
      <<",\n  \"cop_busy_cycles\": "<<busy<<",\n  \"last_cpu_address\": "<<top.cpu_address
      <<",\n  \"buffer_nonzero_words\": {";
    for(size_t i=0;i<names.size();++i) { if(i)report<<","; report<<"\""<<names[i]<<"\": "<<nonzero[i]; }
    report<<"},\n";
#ifdef FULL_VIDEO
    std::ofstream picture("sim/results/rtl-live-logo"+run_tag+".ppm",std::ios::binary);
    picture<<"P6\n320 256\n255\n";
    picture.write(reinterpret_cast<char*>(av_completed.data()),av_completed.size());
    report<<"  \"complete_video_frames\": "<<av_complete_frames<<",\n  \"gfx_rom_requests\": "<<gfx_requests<<",\n";
    report<<"  \"sound\": {\"z80_fetches\":"<<zfetch<<",\"irq_acks\":"<<ziack
          <<",\"writes\":"<<zwrite<<",\"coin_reads\":"<<zcoinread<<",\"fm_data_writes\":"<<zfmwrite
          <<",\"oki_writes\":"<<zokiwrite<<",\"samples\":"<<asamples<<",\"nonzero_samples\":"<<anonzero
          <<",\"pending_cycles\":"<<zpendingcycles<<",\"last_address\":"<<top.sound_address<<"},\n";
#endif
    report<<"  \"device_writes\": {";
    bool first=true;
    for (auto& [a,n]:device_writes) { if(!first) report<<","; first=false; report<<"\n    \""<<a<<"\": "<<n; }
    report << "\n  }\n}\n"; report.close();
    std::cout<<"Board cycles="<<cycles<<" ROM="<<requests<<" writes="<<writes
      <<" IRQ="<<irqs<<" videoDMA="<<dma<<" paletteDMA="<<pal_dma<<" COPbusy="<<busy<<" reads="<<reads<<"\n";
    std::cout<<"Write milestones (cycle per 10000 CPU writes):";
    for(auto m:write_milestones) std::cout<<' '<<m;
    std::cout<<"\n";
    return (requests>100 && writes>100) ? 0 : 1;
}
