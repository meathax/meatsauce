// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_mister_controls.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void ck(bool b,const char*s){++checks;if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{Vcs_mister_controls d;auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();};
 d.reset=1;tick();d.reset=0;tick();ck(d.p1_p2_n==0xffffffff&&d.p3_p4_n==0xffffffff&&d.system_n==255&&d.dips_n==255,"pull-up defaults");
 // MAME crystal.cpp: B1/B2/B3/B4 at 0/2/4/6, U/D/L/R at 16/18/20/22; P2 adjacent (game id 0 = crystal).
 const int pin[8]={22,20,18,16,0,2,4,6};
 for(unsigned player=0;player<2;player++)for(unsigned bit=0;bit<32;bit++){
  d.joystick_0=d.joystick_1=0;if(player)d.joystick_1=1u<<bit;else d.joystick_0=1u<<bit;d.eval();
  unsigned p=0xffffffff,s=255;if(bit<8)p&=~(1u<<(pin[bit]+player));if(bit==8)s&=~(1u<<player);if(bit==9)s&=~(1u<<(4+player));if(bit==11)s&=~64u;if(bit==12)s&=~128u;
  ck(d.p1_p2_n==p&&d.system_n==s&&d.p3_p4_n==0xffffffff,"one-hot MAME player/system pins");
 }
 d.joystick_0=d.joystick_1=0;tick();
 for(unsigned value=0;value<256;value++){d.ioctl_download=1;d.ioctl_wr=1;d.ioctl_index=254;d.ioctl_addr=0;d.ioctl_dout=value;tick();ck(d.dips_n==value,"all DIP combinations");}
 d.ioctl_addr=1;d.ioctl_dout=0;tick();ck(d.dips_n==255,"DIP range guard");d.ioctl_addr=0;d.ioctl_index=510;tick();ck(d.dips_n==255,"full index guard");d.ioctl_index=254;d.ioctl_download=0;tick();ck(d.dips_n==0,"DIP writes independent of ROM download");
 d.ioctl_wr=0;d.reset=1;tick();ck(d.dips_n==0,"warm reset preserves DIPs");d.reset=0;tick();
 d.joystick_0=1u<<10;tick();ck(d.pause_cpu,"pause press");tick();ck(d.pause_cpu,"held pause");d.joystick_0=0;tick();d.joystick_1=1u<<10;tick();ck(!d.pause_cpu,"P2 unpause");d.osd_open=1;d.eval();ck(d.pause_cpu,"OSD pause");d.osd_open=0;d.persistence_pause=1;d.eval();ck(d.pause_cpu,"persistence pause");
 d.persistence_pause=0;d.joystick_0=d.joystick_1=d.joystick_2=0;
 // OSD Test switch drives the test input (crystal bit 7).
 d.test_switch=1;d.eval();ck(d.system_n==0x7f,"OSD test switch");d.test_switch=0;
 // officeye/urachamu (game id 4/5): MAME officeye P1_P2 layout, three players, no SYSTEM starts.
 const unsigned buttons_officeye[3][3]={{16,18,20},{0,2,4},{17,19,21}};const unsigned start_officeye[3]={22,6,23};
 for(unsigned g=4;g<=5;g++){d.game_id=g;
  for(unsigned pl=0;pl<3;pl++){for(unsigned b=0;b<4;b++){d.joystick_0=d.joystick_1=d.joystick_2=0;unsigned v=(b<3)?(1u<<(4+b)):(1u<<8);
   if(pl==0)d.joystick_0=v;else if(pl==1)d.joystick_1=v;else d.joystick_2=v;d.eval();
   unsigned bit=b<3?buttons_officeye[pl][b]:start_officeye[pl];ck(d.p1_p2_n==~(1u<<bit)&&d.system_n==255&&d.p3_p4_n==0xffffffff,"officeye three-player pins");}}
  d.joystick_0=d.joystick_1=d.joystick_2=0;d.joystick_2=1u<<9;d.eval();ck(d.system_n==0xdf,"officeye P3 coin = coin 2");}
 // topbladv (game id 3): two buttons, impulse coins (one 60 Hz frame), test bit 6, service credit bit 7.
 d.game_id=3;d.joystick_0=d.joystick_1=d.joystick_2=0;tick();d.joystick_0=1u<<6;d.eval();ck(d.p1_p2_n==0xffffffff,"topbladv no button 3");
 d.joystick_0=1u<<12;d.eval();ck(d.system_n==0xbf,"topbladv test bit 6");d.joystick_0=1u<<11;d.eval();ck(d.system_n==0x7f,"topbladv service bit 7");
 d.joystick_0=1u<<9;tick();ck(d.system_n==0xef,"topbladv coin impulse start");for(int i=0;i<1430520;i++)tick();ck(d.system_n==0xff,"topbladv coin impulse ends after one frame while held");
 d.joystick_0=0;d.game_id=0;tick();
 std::cout<<"PASS controls: "<<checks<<" checks; both players, button 4, DIPs, service/menu, pause/reset, test switch, officeye/urachamu three players, topbladv impulse coins"<<std::endl;return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL controls: "<<e.what()<<"\n";return 1;}
}
