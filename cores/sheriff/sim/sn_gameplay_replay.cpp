// SPDX-License-Identifier: GPL-2.0-or-later
// Native chip replay of recorded real-8080 output writes; no CPU/gameplay claim.
#include "Vsn_gameplay_replay.h"
#include "verilated.h"
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>
struct Write { uint64_t tick; unsigned port,data; };
int main(int argc,char **argv) {
    if(argc!=4)return 2;
    Verilated::commandArgs(argc,argv);
    std::vector<Write> writes;
    std::ifstream io(argv[1]);std::string line;std::getline(io,line);
    while(std::getline(io,line)) {
        std::stringstream row(line);std::vector<std::string> columns;std::string value;
        while(std::getline(row,value,','))columns.push_back(value);
        if(columns.size()<7)return 3;
        unsigned port=std::stoul(columns[5])&7;
        if(columns[4]=="out" && (port==4||port==5))
            writes.push_back({std::stoull(columns[0]),port,unsigned(std::stoul(columns[6]))});
    }
    std::ifstream ref(argv[2],std::ios::binary);
    std::vector<int16_t> expected;
    int16_t value;
    while(ref.read(reinterpret_cast<char*>(&value),2))expected.push_back(value);
    if(writes.empty()||expected.empty())return 4;
    std::filesystem::path output(argv[3]);std::filesystem::create_directories(output);
    std::ofstream old_pcm(output/"old-sn.raw",std::ios::binary),new_pcm(output/"current-sn.raw",std::ios::binary);
    std::ofstream trace(output/"capacitor_window.csv");
    trace<<"sample,tick,old_pcm,current_pcm,enabled,mode,mixer,voltage5,ad_Q32,vco_Q32,noise_Q32,shot_Q32,shot_running,filtered_noise,vco_bit\n";
    Vsn_gameplay_replay b;
    auto clock=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};
    b.reset=1;b.write=0;b.port=0;b.data=0;
    for(unsigned i=0;i<4;i++)clock();
    b.reset=0;size_t next=0,samples=0;
    uint64_t differences=0,changed=0,first=~0ULL;
    for(uint64_t tick=0;samples<expected.size();tick++) {
        b.write=0;
        if(next<writes.size()&&writes[next].tick==tick) {
            b.write=1;b.port=writes[next].port;b.data=writes[next].data;next++;
        }
        clock();
        if(b.old_ce!=b.current_ce || b.old_ad!=b.current_ad || b.old_vco!=b.current_vco ||
           b.old_noise!=b.current_noise || b.old_slf!=b.current_slf)return 5;
        if(!b.current_ce)continue;
        if(tick!=1049+1050*samples)return 6;
        int16_t old_sample=b.old_pcm,current_sample=b.current_pcm;
        old_pcm.write(reinterpret_cast<char*>(&old_sample),2);
        new_pcm.write(reinterpret_cast<char*>(&current_sample),2);
        if(old_sample!=expected[samples]) {differences++;if(first==~0ULL)first=samples;}
        changed+=old_sample!=current_sample;
        bool observe=samples<8||(samples>=780380&&samples<=780405)||
                     (samples>=780610&&samples<=780635)||(samples>=781180&&samples<=781200);
        if(observe)trace<<samples<<','<<tick<<','<<old_sample<<','<<current_sample<<','
            <<unsigned(b.enabled)<<','<<unsigned(b.mode)<<','<<unsigned(b.mixer)<<','<<unsigned(b.voltage5)<<','
            <<b.current_ad<<','<<b.current_vco<<','<<b.current_noise<<','<<b.current_shot<<','
            <<unsigned(b.current_shot_running)<<','<<unsigned(b.current_filter)<<','<<unsigned(b.current_vco_bit)<<'\n';
        samples++;
        if(samples%100000==0)std::cout<<"samples="<<samples<<std::endl;
    }
    std::ofstream result(output/"native-result.json");
    result<<"{\"samples\":"<<samples<<",\"old_identity_differences\":"<<differences
          <<",\"first_difference\":"<<(first==~0ULL?"null":std::to_string(first))
          <<",\"changed_current_samples\":"<<changed<<",\"capacitor_state_identical\":true}\n";
    std::cout<<"samples="<<samples<<" old_identity_differences="<<differences<<" changed_current_samples="<<changed<<'\n';
    return differences?1:0;
}
