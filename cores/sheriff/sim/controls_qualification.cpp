// SPDX-License-Identifier: GPL-2.0-or-later
#include "Vn8080_controls.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);Vn8080_controls b;
 auto tick=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};
 auto require=[&](bool ok,const char*why){if(!ok)throw std::runtime_error(why);};
 b.reset=1;b.joy0=b.joy1=0;b.analog_l0=b.analog_l1=b.analog_r0=b.analog_r1=0;b.ps2_key=0;b.rotate_aim=0;tick();b.reset=0;
 // Independent player ports and eight valid directions, using the MAME masks.
 const unsigned vectors[]={0x10,0x50,0x40,0x60,0x20,0xa0,0x80,0x90};
for(auto aim:vectors){b.joy0=(aim>>4)<<8 | 8;b.joy1=(aim>>4)<<8 | 4;tick();require(b.input0==(aim|4),"P1 independent movement/aim");require(b.input1==(aim|8),"P2 independent movement/aim");}
// Protocol directions R,DR,D,DL,L,UL,U,UR, independent of aim buttons.
const unsigned mister_move[]={1,5,4,6,2,10,8,9};
const unsigned sheriff_move[]={1,9,8,10,2,6,4,5};
for(unsigned i=0;i<8;i++){b.joy0=0x100|mister_move[i];b.joy1=0x200|mister_move[i];tick();require(b.input0==(0x10|sheriff_move[i]),"MiSTer P1 eight-direction movement");require(b.input1==(0x20|sheriff_move[i]),"MiSTer P2 eight-direction movement");}
 b.joy0=0xf0;b.joy1=0x10;tick();require(b.input2==0x8f,"coin/start/player fire wiring");
 b.joy0=b.joy1=0;b.analog_l0=0x8121;b.analog_r0=0x7fdf;tick();require(b.input0==0xa5,"signed analog axes");
 b.analog_l0=b.analog_r0=0x2020;tick();require(b.input0==0,"analog deadzone");b.analog_l0=b.analog_r0=0;
 auto key=[&](unsigned code,bool make){b.ps2_key=((b.ps2_key^0x400)&0x400)|(make?0x200:0)|code;tick();};
 key(0x1d,1);key(0x4b,1);key(0x29,1);require(b.input0==0x14 && b.input2==1,"P1 keyboard make");
 key(0x1d,0);key(0x4b,0);key(0x29,0);require(b.input0==0 && b.input2==0,"keyboard break");
 key(0x174,1);key(0x75,1);key(0x5a,1);require(b.input1==0x41 && b.input2==2,"P2 keyboard and extended codes");
 key(0x174,0);key(0x75,0);key(0x5a,0);
 key(0x4d,1);require(b.paused,"pause make");key(0x4d,1);require(b.paused,"pause repeat must not toggle");key(0x4d,0);key(0x4d,1);require(!b.paused,"pause second press");key(0x4d,0);
 b.rotate_aim=1;tick();const unsigned clockwise[]={0x90,0x80,0xa0,0x20,0x60,0x40,0x50,0x10};
 for(auto aim:clockwise){b.joy0=0x100;tick();require(b.input0==aim,"rotary aim clockwise");tick();require(b.input0==aim,"rotary hold must not repeat");b.joy0=0;tick();}
 b.joy0=0x200;tick();require(b.input0==0x50,"rotary counterclockwise");
 std::cout<<"PASS: two independent players, eight aim directions, signed analog/deadzone, keyboard make/break, coin/start/fire, rotary and pause\n";
}
