#include "Valpha68kn_ymssg_pitch_probe.h"
#include "verilated.h"
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <vector>

struct Edges {
    unsigned last=0,count=0,min_gap=~0u,max_gap=0;
    std::vector<unsigned> first;
    void rise(unsigned cycle) {
        if(last) {min_gap=std::min(min_gap,cycle-last);max_gap=std::max(max_gap,cycle-last);}
        last=cycle;count++;if(first.size()<8) first.push_back(cycle);
    }
    bool exact(unsigned gap) const {return count>=2 && min_gap==gap && max_gap==gap;}
    void json() const {
        std::cout<<"{\"rises\":"<<count<<",\"minimum_gap\":"<<(count>=2 ? min_gap : 0)
                 <<",\"maximum_gap\":"<<(count>=2 ? max_gap : 0)<<",\"first_rising_ticks\":[";
        for(unsigned i=0;i<first.size();i++) {if(i) std::cout<<',';std::cout<<first[i];}
        std::cout<<"]}";
    }
};
int main(int argc,char** argv) try {
    Verilated::commandArgs(argc,argv);Valpha68kn_ymssg_pitch_probe top;
    top.clk=0;top.reset=1;top.io_wr=0;top.io_rd=0;top.io_addr=0;top.io_data=0;top.read_addr=0;
    auto tick=[&]() {top.clk=0;top.eval();top.clk=1;top.eval();};
    auto clocks=[&](unsigned n) {while(n--) tick();};
    auto reset=[&]() {top.io_wr=0;top.io_rd=0;top.reset=1;clocks(256);top.reset=0;clocks(256);};
    auto write=[&](unsigned port,unsigned data) {
        top.io_addr=port;top.io_data=data;top.io_wr=1;tick();top.io_wr=0;clocks(24);
    };
    auto status=[&]() {top.io_rd=1;top.read_addr=0x10;clocks(2);auto v=top.read_data;top.io_rd=0;return v;};
    auto wait_busy=[&]() {
        for(unsigned n=0;status()&0x80;n++) {if(n>10000) throw std::runtime_error("YM busy timeout");tick();}
    };
    auto ym=[&](unsigned reg,unsigned data) {wait_busy();write(0x10,reg);write(0x11,data);wait_busy();};
    bool all=true;
    for(unsigned period:{0u,1u,37u}) {
        reset();ym(0,period&255);ym(1,period>>8);ym(7,0x3e);ym(8,15);ym(9,0);ym(10,0);clocks(10000);
        const bool accepted=top.accepted_period==period && top.accepted_mixer==0x3e && top.accepted_volume==15 && top.accepted_prescale==2;
        Edges chip,ssg,bit,a;unsigned old_chip=top.chip_cen,old_ssg=top.ssg_cen,old_bit=top.tone_bit,old_a=top.ssg_a;
        unsigned minimum=255,maximum=0;
        for(unsigned cycle=1;cycle<=500000;cycle++) {
            tick();unsigned v=top.ssg_a;minimum=std::min(minimum,v);maximum=std::max(maximum,v);
            if(top.chip_cen && !old_chip) chip.rise(cycle);
            if(top.ssg_cen && !old_ssg) ssg.rise(cycle);
            if(top.tone_bit && !old_bit) bit.rise(cycle);
            if(v && !old_a) a.rise(cycle);
            old_chip=top.chip_cen;old_ssg=top.ssg_cen;old_bit=top.tone_bit;old_a=v;
        }
        const unsigned expected=768*std::max(period,1u);
        const bool pass=accepted && chip.exact(24) && ssg.exact(96) && bit.exact(expected) && a.exact(expected);
        all &= pass;
        std::cout<<"{\"period\":"<<period<<",\"observed_master_ticks\":500000,\"accepted_registers_exact\":"<<(accepted ? "true":"false")
                 <<",\"accepted_prescale\":"<<unsigned(top.accepted_prescale)<<",\"accepted_period\":"<<unsigned(top.accepted_period)
                 <<",\"minimum_channel_A\":"<<minimum<<",\"maximum_channel_A\":"<<maximum
                 <<",\"nominal_expected_rising_gap\":"<<expected<<",\"nominal_expected_Hz\":"<<(48000000.0/expected)<<",\"chip_enable\":";
        chip.json();std::cout<<",\"SSG_enable\":";ssg.json();std::cout<<",\"tone_divider_bit_A\":";bit.json();std::cout<<",\"channel_A_output\":";a.json();
        std::cout<<",\"nominal_frequency_pass\":"<<(pass ? "true":"false")<<"}\n";
    }
    std::cout<<"{\"all_nominal_frequency_cases_pass\":"<<(all ? "true":"false")<<",\"scope\":\"isolated current production YM2203 SSG tone only\"}\n";
    top.final();return all ? 0 : 1;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 3;}
