// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vraster_counter_qualification.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

void need(bool condition,const char* message) {
    if(!condition) throw std::runtime_error(message);
}
int main(int argc,char** argv) {
 try {
    Verilated::commandArgs(argc,argv);
    Vraster_counter_qualification top;
    auto edge=[&](){top.clk=0;top.eval();top.clk=1;top.eval();};
    top.reset=1;top.ce_counter=0;edge();top.reset=0;
    unsigned active=0,blank=0,inc=0,rejected=0,holds=0,wraps=0;
    unsigned vb_rises=0,vb_falls=0;
    int last_inc=-1;
    std::array<unsigned,256> row_increments{};
    constexpr unsigned pixels=320*256*2;
    for(unsigned pixel=0;pixel<pixels;pixel++) {
        unsigned old_v=top.vertical,old_vb=top.vb;
        bool count=top.carry && top.active;
        bool blank_carry=top.carry && !top.active;
        if(top.active) active++;else blank++;
        // CK/4 CE is one of ten master edges; all idle master edges hold.
        for(unsigned master=0;master<9;master++) {
            unsigned phase=top.phase,upper=top.upper;
            bool a=top.active,b=top.hb,c=top.carry;
            top.ce_counter=0;edge();
            need(top.phase==phase && top.upper==upper && top.active==a &&
                 top.hb==b && top.carry==c && top.vertical==old_v && top.vb==old_vb,
                 "state changed without counter CE");holds++;
        }
        top.ce_counter=1;edge();
        if(blank_carry) {
            need(top.vertical==old_v,"blank-end RCO incorrectly incremented vertical");
            rejected++;
        }
        if(count) {
            need(top.vertical==((old_v+1)&255),"active-end counter lost a row");
            if(last_inc>=0) need(int(pixel)-last_inc==320,"row period is not 320 counter clocks");
            last_inc=pixel;inc++;row_increments[top.vertical]++;
            if(top.vertical==0) wraps++;
        } else need(top.vertical==old_v,"vertical changed outside active-end carry");
        if(top.vb!=old_vb) {
            if(top.vb) {need(top.vertical==240,"VB set outside line240");vb_rises++;}
            else {need(top.vertical==16,"VB cleared outside line16");vb_falls++;}
        }
        need(bool(top.vb)==(top.vertical<16 || top.vertical>=240),"VB active-window mismatch");
        need(top.hb!=top.active,"horizontal polarity mismatch");
    }
    need(active==256*256*2 && blank==64*256*2,"horizontal duty/period mismatch");
    need(inc==512 && rejected==512 && wraps==2,"vertical frame/carry count mismatch");
    need(vb_rises==2 && vb_falls==2,"vertical blanking latch transition count mismatch");
    for(auto visits:row_increments) need(visits==2,"a vertical address bit/row was omitted");
    need(top.phase==0 && top.upper==12 && !top.active && top.vertical==0 && top.vb,
         "two-field steady-state origin did not repeat");
    std::cout<<"PASS counter_pixels="<<pixels<<" vertical_increments="<<inc
             <<" rejected_blank_carries="<<rejected<<" field_counter_clocks=81920"
             <<" active_rows_per_field=224 ce_hold_checks="<<holds<<"\n";
    return 0;
 } catch(const std::exception& e) {
    std::cerr<<"FAIL "<<e.what()<<"\n";return 1;
 }
}
