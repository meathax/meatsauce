#include "Valpha68kn_audio.h"
#include "verilated.h"
#include <array>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>

// Diagnostic replay of writes observed from a real CPU run. Actual JT03/JT49
// and mixer RTL execute; this does not replace a real CPU/game acceptance run.
struct Event {uint64_t tick;bool dac;unsigned address,data;};
struct Stats {
    double sum=0,squared=0;unsigned count=0;
    void add(double v) {sum+=v;squared+=v*v;count++;}
    double mean() const {return count ? sum/count : 0;}
    double rms() const {return count ? std::sqrt(std::max(0.0,squared/count-mean()*mean())) : 0;}
};
static void le(std::ostream& out,uint32_t value,unsigned bytes) {
    for(unsigned i=0;i<bytes;i++) out.put((value>>(i*8))&255);
}
int main(int argc,char** argv) try {
    if(argc!=5) {std::cerr<<"usage: audio_replay_sim observed_events.csv fields profile output\n";return 2;}
    Verilated::commandArgs(argc,argv);
    unsigned fields=std::stoul(argv[2]),profile=std::stoul(argv[3]);
    if(!fields || profile>2) throw std::runtime_error("fields/profile range");
    std::ifstream in(argv[1]);if(!in) throw std::runtime_error("missing events");
    std::string line;std::getline(in,line);
    if(!line.empty() && line.back()=='\r') line.pop_back();
    if(line!="tick,frame,kind,address,data") throw std::runtime_error("event header");
    std::vector<Event> events;
    while(std::getline(in,line)) {
        std::istringstream stream(line);std::array<std::string,5> values;
        for(auto& v:values) if(!std::getline(stream,v,',')) throw std::runtime_error("event row");
        Event e{std::stoull(values[0]),values[2]=="dac",unsigned(std::stoul(values[3])),unsigned(std::stoul(values[4]))};
        if(e.data>255 || (values[2]!="dac" && values[2]!="write") ||
           (e.dac ? e.address!=57348 : e.address>255) ||
           (!events.empty() && e.tick<=events.back().tick)) throw std::runtime_error("invalid event/order");
        events.push_back(e);
    }
    std::filesystem::path output(argv[4]);std::filesystem::create_directories(output);
    std::ofstream components(output/"components.csv");
    components<<"second,samples,fm_mean,fm_ac_rms,ym_ssg_mean,ym_ssg_ac_rms,ay1_mean,ay1_ac_rms,ay2_mean,ay2_ac_rms,dac_mean,dac_ac_rms,mix_mean,mix_ac_rms\n";
    Valpha68kn_audio top;top.clk=0;top.reset=1;top.io_wr=0;top.io_rd=0;
    top.io_addr=0;top.io_data=0;top.read_addr=255;top.profile=profile;top.dac=0;
    auto tick=[&]() {top.clk=0;top.eval();top.clk=1;top.eval();};
    for(unsigned i=0;i<4096;i++) tick();top.reset=0;
    const uint64_t duration=uint64_t(fields)*384*264*8;
    size_t cursor=0;unsigned dac_writes=0,io_writes=0,second=0;
    std::vector<int16_t> pcm;std::array<Stats,6> stats;
    auto flush=[&]() {
        if(!stats[0].count) return;
        components<<second++<<','<<stats[0].count;
        for(auto& s:stats) {components<<','<<s.mean()<<','<<s.rms();s={};}
        components<<'\n';components.flush();
    };
    for(uint64_t n=1;n<=duration;n++) {
        top.io_wr=0;
        // The source recorder observes the board's post-edge registered pulse.
        // Sound-chip and mixer consumers see it on the following master edge.
        if(cursor<events.size() && events[cursor].tick+1==n) {
            const auto& e=events[cursor++];
            if(e.dac) {top.dac=e.data;dac_writes++;}
            else {top.io_wr=1;top.io_addr=e.address;top.io_data=e.data;io_writes++;}
        }
        tick();
        if(top.sample_ce) {
            int16_t sample=top.sample;pcm.push_back(sample);
            auto ay=[](unsigned v) {return (v/255.0-0.75)*16384.0;};
            const double values[]={int16_t(top.debug_fm)*0.30,top.debug_ym_psg/255.0*16382.0*0.30,
                ay(top.debug_ay1_psg)*0.30,ay(top.debug_ay2_psg)*(profile==2?0.45:0.60),
                (int(top.dac)-128)*128.0,double(sample)};
            for(unsigned i=0;i<6;i++) stats[i].add(values[i]);
            if(stats[0].count==48000) flush();
        }
        if(n%(384*264*8*30ull)==0)
            std::cout<<"fields="<<n/(384*264*8)<<" samples="<<pcm.size()<<" events="<<cursor<<std::endl;
    }
    flush();std::ofstream wav(output/"audio.wav",std::ios::binary);
    uint32_t bytes=pcm.size()*2;wav.write("RIFF",4);le(wav,36+bytes,4);wav.write("WAVEfmt ",8);
    le(wav,16,4);le(wav,1,2);le(wav,1,2);le(wav,48000,4);le(wav,96000,4);le(wav,2,2);le(wav,16,2);
    wav.write("data",4);le(wav,bytes,4);for(auto v:pcm) le(wav,uint16_t(v),2);
    std::ofstream result(output/"result.json");
    result<<"{\"scope\":\"actual sound/mixer RTL replay of real CPU writes; no CPU/game acceptance\","
        <<"\"fields\":"<<fields<<",\"profile\":"<<profile<<",\"samples\":"<<pcm.size()
        <<",\"applied_events\":"<<cursor<<",\"input_events\":"<<events.size()
        <<",\"io_writes\":"<<io_writes<<",\"dac_writes\":"<<dac_writes
        <<",\"ym_writes\":"<<top.ym_writes<<",\"ay1_writes\":"<<top.ay1_writes
        <<",\"ay2_writes\":"<<top.ay2_writes<<",\"clipped_samples\":"<<top.clipped_samples<<"}\n";
    std::cout<<"completed_fields="<<fields<<" samples="<<pcm.size()<<" events="<<cursor<<std::endl;
    top.final();return 0;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
