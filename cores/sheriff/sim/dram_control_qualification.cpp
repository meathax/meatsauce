// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vn8080_dram_control.h"
#include "verilated.h"
#include <fstream>
#include <iostream>
#include <string>
#include <cstdint>
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    if(argc<3)return 2;
    Vn8080_dram_control b;
    std::ifstream fixture(argv[1]);unsigned count=0;
    unsigned level,address,wr,sync,phi,h,v,rawcas,rawras,com,hread;
    unsigned selector,ar,cas,ras,we,st,ram,disable,write;
    while(fixture>>level>>address>>wr>>sync>>phi>>h>>v>>rawcas>>rawras>>com>>hread
                 >>selector>>ar>>cas>>ras>>we>>st>>ram>>disable>>write) {
        b.cpu_wr_rd_level=level;b.cpu_address=address;b.cpu_wr_n=wr;
        b.cpu_sync=sync;b.phi1_ttl=phi;b.physical_h_byte=h;b.physical_v=v;
        b.raw_cas_n=rawcas;b.raw_ras_n=rawras;b.comadr_n=com;b.hread_n=hread;b.eval();
        if(b.mux_selector!=selector || b.mux_address!=ar || b.dram_cas_n!=cas ||
           b.dram_ras_n!=ras || b.dram_we_n!=we || b.ststb!=st || b.ramstb_n!=ram ||
           b.disable_level!=disable || b.write_predicate!=write) {
            std::cerr<<"FAIL frozen pin case "<<count<<" selector="<<unsigned(b.mux_selector)
                     <<" address="<<unsigned(b.mux_address)<<" ras="<<unsigned(b.dram_ras_n)
                     <<" cas="<<unsigned(b.dram_cas_n)<<" we="<<unsigned(b.dram_we_n)<<std::endl;
            return 1;
        }
        count++;
    }
    if(count!=1024 || !fixture.eof()){std::cerr<<"FAIL fixture count "<<count<<std::endl;return 2;}
    // All CPU row/column addresses, including A14/A15 aliases and every walking bit.
    b.cpu_wr_rd_level=1;b.cpu_wr_n=1;b.cpu_sync=0;b.phi1_ttl=0;
    b.raw_cas_n=1;b.raw_ras_n=1;b.hread_n=1;
    uint64_t cpu_cases=0,video_cases=0;
    for(unsigned a=0;a<65536;a++) {
        b.cpu_address=a;b.comadr_n=1;b.eval();unsigned row=b.mux_address;
        b.comadr_n=0;b.eval();unsigned column=b.mux_address;
        if(row+(column<<7)!=(a&0x3fff)){std::cerr<<"FAIL CPU address "<<a<<std::endl;return 1;}
        cpu_cases++;
    }
    // Physical Hbyte/V levels, without choosing reset/visible/flip coordinates.
    b.hread_n=0;
    for(unsigned vertical=0;vertical<256;vertical++)for(unsigned horizontal=0;horizontal<32;horizontal++) {
        b.physical_h_byte=horizontal;b.physical_v=vertical;
        b.comadr_n=1;b.eval();unsigned row=b.mux_address;
        b.comadr_n=0;b.eval();unsigned column=b.mux_address;
        if(column&64 || row+(column<<7)!=horizontal+(vertical<<5)) {
            std::cerr<<"FAIL video address "<<horizontal<<","<<vertical<<std::endl;return 1;
        }
        video_cases++;
    }
    std::ofstream report(argv[2]);
    report<<"{\"frozen_pin_cases\":"<<count<<",\"frozen_pin_mismatches\":0,\"CPU_address_cases\":"
          <<cpu_cases<<",\"video_address_cases\":"<<video_cases<<",\"address_reconstruction_mismatches\":0}\n";
    std::cout<<"PASS frozen pins="<<count<<" CPU addresses="<<cpu_cases
             <<" video addresses="<<video_cases<<std::endl;return 0;
}
