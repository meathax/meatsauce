// SPDX-License-Identifier: GPL-3.0-or-later
// Compare the optimized decoder against the previous full-width range map.
#include "Vcs_decode_policy_bench.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Vcs_decode_policy_bench d;
        const uint32_t ranges[][2]={{0,0x1ffff},{0x02000000,0x02ffffff},{0x03800000,0x03ffffff},
            {0x04000000,0x047fffff},{0x05000000,0x05ffffff},{0x01400000,0x0140ffff},
            {0x01800000,0x01ffffff},{0x03000000,0x0300ffff},{0x04800000,0x04800fff},
            {0x01200000,0x0120000b},{0x01280000,0x01280003},{0x01320000,0x01320003},{0x44414f4c,0x44414f7f}};
        uint64_t checks=0;
        auto check=[&](uint32_t a,unsigned bank){
            unsigned target=15;uint32_t offset=a;
            for(unsigned i=0;i<13;i++)if(a>=ranges[i][0]&&a<=ranges[i][1]){
                target=i;
                if(i==1||i==2||i==3||i==6)offset=a&0x7fffff;
                else if(i==4)offset=(bank<<24)|(a&0xffffff);
                else if(i!=0)offset=a-ranges[i][0];
                break;
            }
            // Independent cache-policy model: work RAM (both mirrors) read/write; BIOS and
            // the cartridge window read-only (no CPU write caching, MAME ignores ROM writes);
            // first cartridge word and all reads under a non-FF flash command bypass.
            const bool ram=a>=0x02000000&&a<=0x02ffffff,bios=a<=0x1ffff,cart=a>=0x05000000&&a<=0x05ffffff;
            for(unsigned mode=0;mode<4;mode++){
                const bool write=mode&1,override_=mode&2;
                const bool expect_cache=ram||(!write&&(bios||(cart&&a!=0x05000000&&!override_)));
                d.write=write;d.flash_read_override=override_;d.address=a;d.flash_bank=bank;d.eval();
                if(bool(d.cacheable)!=expect_cache){
                    std::cerr<<std::hex<<"address="<<a<<" write="<<write<<" override="<<override_<<" cacheable="<<unsigned(d.cacheable)<<'\n';
                    throw std::runtime_error("cache policy mismatch");
                }++checks;
            }
            d.address=a;d.flash_bank=bank;d.eval();
            if(d.target!=target||d.offset!=offset){
                std::cerr<<std::hex<<"address="<<a<<" bank="<<bank<<" target="<<unsigned(d.target)<<" offset="<<d.offset<<" expected="<<target<<":"<<offset<<"\n";
                throw std::runtime_error("address map mismatch");
            }++checks;
        };
        for(unsigned b=0;b<8;b++)for(auto&r:ranges){
            for(int delta=-128;delta<=128;delta++){check(r[0]+delta,b);check(r[1]+delta,b);}
            for(unsigned bit=0;bit<32;bit++){check(r[0]^(1u<<bit),b);check(r[1]^(1u<<bit),b);}
        }
        uint32_t random=0x4b494e47;
        for(unsigned i=0;i<200000;i++){random^=random<<13;random^=random>>17;random^=random<<5;check(random,i&7);}
        std::cout<<"PASS address_decode: "<<checks<<" previous-map equivalence + cache-policy checks (ROM writes never cacheable), all bank values and aperture boundaries\n";
        return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL address_decode: "<<e.what()<<"\n";return 1;}
}
