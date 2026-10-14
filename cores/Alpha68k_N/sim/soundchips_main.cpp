#include "Valpha68kn_soundchips.h"
#include "verilated.h"
#include <algorithm>
#include <iostream>
#include <set>
#include <stdexcept>
#include <vector>

int main(int argc,char** argv) try {
    Verilated::commandArgs(argc,argv);
    Valpha68kn_soundchips top;
    top.clk=0;top.reset=1;top.io_wr=0;top.io_rd=0;
    top.io_addr=0;top.io_data=0;top.read_addr=0;
    auto tick=[&]() {top.clk=0;top.eval();top.clk=1;top.eval();};
    auto clocks=[&](unsigned n) {while(n--) tick();};
    auto reset=[&]() {top.reset=1;clocks(256);top.reset=0;clocks(256);};
    auto write=[&](unsigned port,unsigned data) {
        top.io_addr=port;top.io_data=data;top.io_wr=1;tick();top.io_wr=0;clocks(24);
    };
    auto ay=[&](unsigned chip,unsigned reg,unsigned data) {
        write(chip==1 ? 0x81 : 0x91,reg);write(chip==1 ? 0x80 : 0x90,data);
    };
    auto read_ay=[&](unsigned chip,unsigned reg) {
        write(chip==1 ? 0x81 : 0x91,reg);top.read_addr=chip==1 ? 0x80 : 0x90;
        top.io_rd=1;clocks(4);auto value=top.read_data;top.io_rd=0;return value;
    };
    reset();
    ay(1,1,0xff);ay(1,6,0xff);ay(1,8,0x0f);ay(2,8,7);
    if(read_ay(1,1)!=15 || read_ay(1,6)!=31 || read_ay(1,8)!=15 || read_ay(2,8)!=7)
        throw std::runtime_error("AY register masks/independent ports failed");
    const unsigned table[]={0,3,5,6,8,11,15,24,30,49,68,90,120,153,202,255};
    ay(1,7,0x3f);
    for(unsigned level=0;level<16;level++) {
        ay(1,8,level);clocks(512);
        if(top.ay1_a!=table[level]) throw std::runtime_error("AY fixed-volume transfer mismatch");
    }
    std::cout<<"fixed_levels=16 register_masks=pass independent_ports=pass\n";
    for(unsigned period:{0u,1u,37u}) {
        reset();ay(1,0,period&255);ay(1,1,period>>8);ay(1,7,0x3e);ay(1,8,15);
        clocks(10000);
        unsigned previous=top.ay1_a,last=0,rises=0,min_gap=~0u,max_gap=0;
        for(unsigned cycle=1;cycle<=500000;cycle++) {
            tick();unsigned value=top.ay1_a;
            if(value && !previous) {
                if(last) {min_gap=std::min(min_gap,cycle-last);max_gap=std::max(max_gap,cycle-last);}
                last=cycle;rises++;
            }
            previous=value;
        }
        unsigned expected=384*std::max(period,1u);
        if(rises<2 || min_gap!=expected || max_gap!=expected)
            throw std::runtime_error("AY tone frequency mismatch period="+std::to_string(period)+
                " min="+std::to_string(min_gap)+" max="+std::to_string(max_gap));
        std::cout<<"tone_period="<<period<<" rise_gap_clocks="<<min_gap<<" rises="<<rises<<'\n';
    }
    const std::set<unsigned> envelope_table={0,2,3,5,7,10,14,23,29,48,67,89,120,152,202,255};
    for(unsigned period:{0u,3u}) {
        reset();ay(1,7,0x3f);ay(1,8,0x10);ay(1,11,period);ay(1,12,0);ay(1,13,8);
        clocks(10000);
        std::set<unsigned> levels;
        unsigned previous=top.ay1_a,last=0,changes=0,min_gap=~0u,max_gap=0;
        for(unsigned cycle=1;cycle<=100000;cycle++) {
            tick();unsigned value=top.ay1_a;levels.insert(value);
            if(value!=previous) {
                if(last) {min_gap=std::min(min_gap,cycle-last);max_gap=std::max(max_gap,cycle-last);}
                last=cycle;changes++;
            }
            previous=value;
        }
        unsigned expected=24*(period ? 16*period : 8);
        if(levels!=envelope_table || changes<16 || min_gap!=expected || max_gap!=expected)
            throw std::runtime_error("AY envelope level/rate mismatch period="+std::to_string(period)+
                " levels="+std::to_string(levels.size())+" min="+std::to_string(min_gap)+" max="+std::to_string(max_gap));
        std::cout<<"envelope_period="<<period<<" levels="<<levels.size()<<" change_gap_clocks="<<min_gap<<'\n';
    }
    auto status=[&]() {top.io_rd=1;top.read_addr=0x10;clocks(2);auto v=top.read_data;top.io_rd=0;return v;};
    auto wait_busy=[&]() {
        for(unsigned count=0;status()&0x80;count++) {
            if(count>10000) throw std::runtime_error("YM busy timeout");tick();
        }
    };
    auto ym=[&](unsigned reg,unsigned data) {wait_busy();write(0x10,reg);write(0x11,data);wait_busy();};
    reset();ym(0x24,0xff);ym(0x25,3);ym(0x27,5);clocks(100000);
    if(!(status()&1) || top.ym_irq_n) throw std::runtime_error("YM timer A status/IRQ failed");
    ym(0x27,0x10);clocks(10000);
    if((status()&1) || !top.ym_irq_n) throw std::runtime_error("YM timer A clear failed");
    reset();
    if(read_ay(1,8)!=0 || read_ay(2,8)!=0 || top.ay1_a || top.ay2_a)
        throw std::runtime_error("warm reset retained AY state");
    std::cout<<"ym_timer_A=pass warm_reset=pass scope=isolated_chip_contracts_only\n";
    top.final();return 0;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
