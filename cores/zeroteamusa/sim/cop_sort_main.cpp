// Replay MAME-observed Zero Team sort-DMA ($6FE) cases through the production COP RTL.
// Reference semantics: stable sort of the lookup table by the signed 32-bit key at
// (sort_ram+val), n = trigger_data+1 (the observed table has data+1 live entries
// followed by a zero terminator), parameter 2 = descending.
#include "Vzero_cop_math_top.h"
#include "verilated.h"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>
int main(int argc,char**argv){
    if(argc<2)throw std::runtime_error("sort-cases.csv expected");
    Verilated::commandArgs(argc,argv);
    std::ifstream in(argv[1]);std::string line;std::getline(in,line);
    unsigned cases=0,bad_np1=0,bad_n=0,shown=0;
    while(std::getline(in,line)){
        std::stringstream ss(line);std::string f[7];
        for(int i=0;i<7;++i)std::getline(ss,f[i],',');
        if(f[5]!="before")continue;
        unsigned frame=std::stoul(f[0]),data=std::stoul(f[1]),ram=std::stoul(f[2],0,16),lut=std::stoul(f[3],0,16),param=std::stoul(f[4]);
        struct E{uint16_t val;int32_t key;};std::vector<E> ent;
        std::stringstream es(f[6]);std::string tok;
        while(es>>tok){unsigned v,k,x;sscanf(tok.c_str(),"%x:%x:%x",&v,&k,&x);ent.push_back({(uint16_t)v,(int32_t)k});}
        Vzero_cop_math_top top;std::vector<uint16_t> memory(0x80000,0);
        for(unsigned i=0;i<ent.size();++i){
            memory[(lut+2*i)/2]=ent[i].val;
            memory[(ram+ent[i].val)/2]=(uint16_t)(ent[i].key&0xffff);
            memory[(ram+ent[i].val+2)/2]=(uint16_t)((ent[i].key>>16)&0xffff);
        }
        auto expect=[&](unsigned n){
            std::vector<E> e(ent.begin(),ent.begin()+n);
            std::stable_sort(e.begin(),e.end(),[&](const E&a,const E&b){return param==2?a.key>b.key:a.key<b.key;});
            std::vector<uint16_t> r;for(auto&x:e)r.push_back(x.val);return r;};
        uint16_t sp=0,rp=0;
        auto tick=[&](){
            top.clk=0;top.eval();
            uint16_t ns=memory.at((top.source_address&0xfffff)/2),nr=memory.at(top.ram_address);
            if(top.ram_write){auto&t=memory.at(top.ram_address);
                if(top.ram_be&1)t=(t&0xff00)|(top.ram_write_data&0xff);
                if(top.ram_be&2)t=(t&0xff)|(top.ram_write_data&0xff00);}
            top.cop_rom_ready=0;top.clk=1;top.eval();
            top.source_data=sp;top.ram_read_data=rp;sp=ns;rp=nr;};
        top.cs=top.wr=top.rd=0;top.reset=1;top.source_data=top.ram_read_data=0;top.cop_rom_data=0;top.cop_rom_ready=0;top.rom_bank=0;
        for(int i=0;i<20;++i)tick();top.reset=0;
        auto write=[&](uint32_t a,uint16_t d){top.address=(a-0x400)/2;top.write_data=d;top.cs=top.wr=1;tick();top.cs=top.wr=0;for(int i=0;i<6;++i)tick();};
        write(0x450,ram>>16);write(0x452,ram&0xffff);write(0x454,lut>>16);write(0x456,lut&0xffff);write(0x458,param);write(0x6fe,data);
        for(int i=0;i<20000;++i){tick();if(i>12&&!top.busy&&!top.stall)break;}
        std::vector<uint16_t> got;for(unsigned i=0;i<data+1;++i)got.push_back(memory[(lut+2*i)/2]);
        auto e1=expect(data+1);
        bool ok1=got==e1;
        std::vector<uint16_t> e0=expect(data);e0.push_back(ent[data].val);
        bool ok0=got==e0;
        ++cases;bad_np1+=!ok1;bad_n+=!ok0;
        if(!ok1&&shown++<3){std::cout<<"MISMATCH frame="<<frame<<" data="<<data<<"\n got:";for(auto v:got)std::cout<<' '<<std::hex<<v;std::cout<<"\n exp:";for(auto v:e1)std::cout<<' '<<std::hex<<v;std::cout<<std::dec<<"\n";}
        top.final();
    }
    std::cout<<"cases="<<cases<<" mismatch(n=data+1)="<<bad_np1<<" mismatch(n=data)="<<bad_n<<"\n";
    return bad_np1?1:0;
}
