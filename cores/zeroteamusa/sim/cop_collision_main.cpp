// Replay observed USA collision operands through production COP RTL only.
#include "Vzero_cop_math_top.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>

int main(int argc,char**argv) {
    if(argc!=4&&argc!=5)throw std::runtime_error("Expected collision CSV, result JSON, observed boot COP writes, optional --mixed-ram");
    const bool mixed_ram=argc==5&&std::string(argv[4])=="--mixed-ram";
    if(argc==5&&!mixed_ram)throw std::runtime_error("Unknown collision option");
    Verilated::commandArgs(argc,argv);
    std::ifstream fixture(argv[1]);if(!fixture)throw std::runtime_error("Missing collision fixture");
    std::string line;std::getline(fixture,line);
    std::ifstream boot(argv[3]);if(!boot)throw std::runtime_error("Missing observed macro upload");
    std::getline(boot,line);std::vector<std::array<uint32_t,2>> uploads;
    while(std::getline(boot,line)) {
        std::replace(line.begin(),line.end(),',',' ');std::istringstream row(line);
        uint32_t frame,address,data,mask;
        if(!(row>>frame>>address>>data>>mask))throw std::runtime_error("Bad boot write");
        if(frame==0&&(address==0x432||address==0x434||address==0x438||address==0x43a||address==0x43c)) {
            if(mask!=65535)throw std::runtime_error("Partial macro upload unsupported by this fixture");
            uploads.push_back({address,data});
        }
    }
    if(uploads.size()<28)throw std::runtime_error("Incomplete observed boot upload");
    uint64_t cases=0,different=0,writes_total=0,hits=0,rom_total=0,descriptor_errors=0,expected_rom=0,mapping_errors=0;
    while(std::getline(fixture,line)) {
        std::replace(line.begin(),line.end(),',',' ');std::istringstream row(line);
        std::array<uint32_t,36> v{};
        for(auto& n:v)if(!(row>>n))throw std::runtime_error("Bad collision case");
        Vzero_cop_math_top top;std::vector<uint16_t> memory(0x80000),rom(0x80000,0xdead);
        top.rom_bank=cases%2;
        auto is_rom=[](uint32_t a){return a>=0x20000&&a<0x100000;};
        auto physical=[&](uint32_t a){return a<0x40000?uint32_t(top.rom_bank)*0x20000+(a&0x1ffff):a;};
        if(mixed_ram) {
            for(unsigned index:{13u,19u}) {
                if(cases%4&1)v[index]=0x1ff00+(index==19?2:0);
                if(cases%4&2){v[index+1]=0xf100+(index==19?8:0);v[index+2]=1;}
            }
            for(unsigned index:{1u,7u,30u})
                if(v[index]>=0x1f000)throw std::runtime_error("RAM fixture overlaps observed position");
        }
        auto put=[&](uint32_t a,uint16_t n){
            if(a&1)throw std::runtime_error("Odd fixture address");
            if(is_rom(a))rom.at(physical(a)/2)=n;else memory.at(a/2)=n;
        };
        auto load_position=[&](unsigned pos) {
            put(v[pos]+2,v[pos+1]);
            for(unsigned i=0;i<3;++i)put(v[pos]+6+4*i,v[pos+2+i]);
        };
        for(unsigned hit:{13u,19u}) {
            put(v[hit],v[hit+1]);
            expected_rom+=is_rom(v[hit]);
            for(unsigned i=0;i<3;++i)put((v[hit+2]<<16)|(v[hit+1]+2*i),v[hit+3+i]);
            for(unsigned i=0;i<3;++i)expected_rom+=is_rom((v[hit+2]<<16)|(v[hit+1]+2*i));
        }
        top.cs=top.wr=top.rd=0;top.reset=1;top.source_data=top.ram_read_data=0;
        top.cop_rom_data=top.cop_rom_ready=0;
        uint64_t cycles=0,due=0;bool pending=false,rom_previous=false;
        uint32_t rom_address=0;uint16_t source_pipeline=0,ram_pipeline=0;
        auto tick=[&](){
            top.clk=0;top.eval();
            uint16_t next_source=is_rom(top.source_address)?0xdead:memory.at((top.source_address&0xfffff)/2);
            uint16_t next_ram=memory.at(top.ram_address);
            if(top.ram_write) {
                ++writes_total;auto& target=memory.at(top.ram_address);
                if(top.ram_be&1)target=(target&0xff00)|(top.ram_write_data&0xff);
                if(top.ram_be&2)target=(target&0xff)|(top.ram_write_data&0xff00);
            }
            if(top.cop_rom_request&&!rom_previous) {
                if(pending)throw std::runtime_error("Overlapping ROM requests");
                pending=true;due=cycles+1+cases%9;rom_address=top.cop_rom_address;++rom_total;
                mapping_errors+=!is_rom(top.cop_rom_logical)||rom_address!=physical(top.cop_rom_logical);
            }
            rom_previous=top.cop_rom_request;
            top.cop_rom_ready=pending&&cycles>=due;
            if(top.cop_rom_ready)top.cop_rom_data=rom.at((rom_address&0xfffff)/2);
            top.clk=1;top.eval();
            if(top.cop_rom_ready)pending=false;
            top.source_data=source_pipeline;top.ram_read_data=ram_pipeline;
            source_pipeline=next_source;ram_pipeline=next_ram;++cycles;
        };
        for(int i=0;i<20;++i)tick();top.reset=0;
        auto write=[&](uint32_t a,uint16_t data){
            top.address=(a-0x400)/2;top.write_data=data;top.cs=top.wr=1;tick();
            top.cs=top.wr=0;for(int i=0;i<6;++i)tick();
        };
        auto wait=[&](){for(int i=0;i<1500;++i){tick();if(i>12&&!top.busy&&!top.stall)return;}throw std::runtime_error("Collision command did not finish");};
        for(const auto& upload:uploads)write(upload[0],upload[1]);
        for(unsigned i=0;i<4;++i) {
            unsigned index=std::array<unsigned,4>{1,7,13,19}[i];
            write(0x4a0+2*i,v[index]>>16);write(0x4c0+2*i,v[index]);
        }
        // Slot-zero bounds survive later position loads until another B100.
        load_position(30);write(0x4a0,v[30]>>16);write(0x4c0,v[30]);
        write(0x500,v[35]);wait();write(0x436,v[15]);write(0x500,0xb100);wait();
        load_position(1);write(0x4a0,v[1]>>16);write(0x4c0,v[1]);write(0x500,v[6]);wait();
        load_position(7);write(0x500,v[12]);wait();write(0x436,v[21]);write(0x500,0xb900);wait();
        const uint32_t expected_hb2=((v[24]>>8)<<16)|uint16_t(int16_t(int8_t(v[24]&255)));
        descriptor_errors+=!top.debug_axis3||top.debug_hb2!=expected_hb2;
        for(unsigned i=0;i<5;++i) {
            top.address=(0x580-0x400)/2+i;top.cs=top.rd=1;for(int k=0;k<3;++k)tick();
            if(top.read_data!=v[25+i]) {
                ++different;if(different<=12)std::cout<<"Collision mismatch frame="<<v[0]<<" register="<<std::hex<<0x580+2*i<<std::dec<<" actual="<<top.read_data<<" expected="<<v[25+i]<<"\n";
            }
            top.cs=top.rd=0;
        }
        ++cases;hits+=v[25]==0;top.final();
    }
    std::ofstream result(argv[2]);result<<"{\"cases\":"<<cases<<",\"register_comparisons\":"<<cases*5<<",\"different_results\":"<<different<<",\"unexpected_writes\":"<<writes_total<<",\"descriptor_errors\":"<<descriptor_errors<<",\"positive_collision_cases\":"<<hits<<",\"separate_rom_requests\":"<<rom_total<<",\"expected_rom_requests\":"<<expected_rom<<",\"mapping_errors\":"<<mapping_errors<<",\"mixed_ram\":"<<(mixed_ram?"true":"false")<<",\"reply_latency_clocks\":[1,9],\"rom_banks\":[0,1],\"source_latency_clocks\":2}\n";
    std::cout<<"Observed US collision cases="<<cases<<" different="<<different<<" unexpectedWrites="<<writes_total<<" descriptorErrors="<<descriptor_errors<<" hits="<<hits<<" ROM="<<rom_total<<"\n";
    return cases>0&&different==0&&writes_total==0&&descriptor_errors==0&&mapping_errors==0&&rom_total==expected_rom?0:1;
}
