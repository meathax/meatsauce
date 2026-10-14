#include "Vzero_cop_math_top.h"
#include "verilated.h"
#include <fstream>
#include <sstream>
#include <iostream>
#include <vector>
#include <array>
#include <algorithm>
#include <stdexcept>

int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    std::ifstream fixture(argc>1 ? argv[1] : "sim/results/mame-play-900-play-2p/distance-cases.csv");
    if(!fixture)throw std::runtime_error("Missing observed MAME distance operands");
    std::string line;std::getline(fixture,line);
    uint64_t cases=0,different=0,unexpected_writes=0;
    while(std::getline(fixture,line)) {
        std::replace(line.begin(),line.end(),',',' ');std::istringstream row(line);
        std::array<uint32_t,10> v{};for(auto& n:v)if(!(row>>n))throw std::runtime_error("Bad distance case");
        Vzero_cop_math_top top;
        std::vector<uint16_t> memory(0x80000);
        auto put32=[&](uint32_t a,uint32_t n){memory.at(a/2)=n;memory.at(a/2+1)=n>>16;};
        put32(v[1]+4,v[3]);put32(v[1]+8,v[4]);put32(v[2]+4,v[5]);put32(v[2]+8,v[6]);
        memory.at((v[1]+0x38)/2)=v[7];memory.at((v[1]+0x3a)/2)=v[8];
        top.cs=top.wr=top.rd=0;top.reset=1;top.source_data=top.ram_read_data=0;
        top.cop_rom_data=top.cop_rom_ready=0;
        uint64_t writes=0;
        uint16_t source_pipeline=0,ram_pipeline=0;
        // Two-clock registered source port, matching the production RAM contract.
        auto tick=[&](){
            top.clk=0;top.eval();
            uint16_t next_source=memory.at((top.source_address&0xfffff)/2);
            uint16_t next_ram=memory.at(top.ram_address);
            if(top.ram_write) {
                ++writes;uint16_t& target=memory.at(top.ram_address);
                if(top.ram_be&1)target=(target&0xff00)|(top.ram_write_data&0xff);
                if(top.ram_be&2)target=(target&0xff)|(top.ram_write_data&0xff00);
            }
            top.clk=1;top.eval();top.source_data=source_pipeline;top.ram_read_data=ram_pipeline;
            source_pipeline=next_source;ram_pipeline=next_ram;
        };
        for(int i=0;i<20;++i)tick();top.reset=0;
        auto write=[&](uint32_t a,uint16_t data){
            top.address=(a-0x400)/2;top.write_data=data;top.cs=top.wr=1;tick();
            top.cs=top.wr=0;for(int i=0;i<6;++i)tick();
        };
        auto wait=[&](){for(int i=0;i<1000;++i){tick();if(i>12&&!top.busy&&!top.stall)return;}throw std::runtime_error("COP command did not complete");};
        write(0x4a0,v[1]>>16);write(0x4c0,v[1]);write(0x4a2,v[2]>>16);write(0x4c2,v[2]);
        // Actual game sequence loads its deltas through angle before distance.
        write(0x500,0x130e);wait();
        writes=0;
        write(0x500,0x3b30);wait();
        top.address=(0x5b2-0x400)/2;top.cs=top.rd=1;for(int i=0;i<3;++i)tick();
        ++cases;bool bad=top.read_data!=v[9];different+=bad;unexpected_writes+=writes;
        if(bad&&different<=8)std::cout<<"Distance mismatch frame="<<v[0]<<" actual="<<top.read_data<<" expected="<<v[9]
            <<" dx="<<int32_t(top.debug_dx)<<" dy="<<int32_t(top.debug_dy)<<" r0="<<v[1]<<" r1="<<v[2]<<"\n";
        if(memory.at((v[1]+0x38)/2)!=v[7]||memory.at((v[1]+0x3a)/2)!=v[8])++unexpected_writes;
        top.final();
    }
    std::ofstream result(argc>2 ? argv[2] : "sim/results/cop-distance.json");
    result<<"{\"cases\":"<<cases<<",\"different_results\":"<<different<<",\"unexpected_distance_writes\":"<<unexpected_writes<<"}\n";
    std::cout<<"Observed US distance cases="<<cases<<" different="<<different<<" unexpectedWrites="<<unexpected_writes<<"\n";
    return cases>0&&different==0&&unexpected_writes==0?0:1;
}
