// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vvr0_gpio.h"
#include "verilated.h"
#include "../obj_dir/rtc_reference/ds1302_reference.hpp"
#include <array>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <vector>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void check(bool ok,const char* why){++checks;if(!ok)throw std::runtime_error(why);}
struct Bench {
    Vvr0_gpio d;ds1302_device oracle;uint32_t pins=0;uint64_t clocks=0;
    void tick(){d.clk=0;d.eval();d.clk=1;d.eval();++clocks;}
    void reset(){
        d.initialize=1;d.reset=1;d.reg_valid=0;d.seed_valid=0;d.restore_valid=0;d.state_address=0;tick();
        d.initialize=0;d.reset=0;pins=0;oracle=ds1302_device{};
        seed({0x80,0,0,1,1,7,0});
    }
    void seed(std::array<uint8_t,7> time){
        uint64_t packed=0;for(unsigned i=0;i<7;i++){packed|=uint64_t(time[i])<<(8*i);oracle.m_reg[i]=time[i];}
        d.seed_bcd=packed;d.seed_valid=1;tick();d.seed_valid=0;tick();
    }
    uint8_t state(unsigned i){d.state_address=i;d.clk=0;d.eval();return d.state_data;}
    uint32_t access(unsigned a,bool write=false,uint32_t data=0,unsigned strobe=15,bool compare=true){
        d.reg_valid=1;d.reg_address=a;d.reg_data=data;d.reg_strobe=strobe;d.reg_write=write;
        // MAME master adds the PIC data pull-up readback at bit 29 (inverted by the CPU-driven bit 29).
        uint32_t wanted=a==4?pins:((uint32_t(oracle.io_r())<<28)|((~pins&0x20000000u)));
        if(write&&a==4){
            uint32_t mask=0;for(unsigned i=0;i<4;i++)if(strobe&(1<<i))mask|=0xffu<<(8*i);
            pins=(pins&~mask)|(data&mask);
            oracle.ce_w((pins>>24)&1);oracle.io_w((pins>>28)&1);oracle.sclk_w((pins>>25)&1);
        }
        tick();check(d.reg_ready&&d.reg_rsp_valid&&!d.reg_rsp_error,"GPIO response");d.reg_valid=0;
        if(!write&&compare)check(d.reg_rsp_data==wanted,"MAME serial/latched read difference");
        return d.reg_rsp_data;
    }
    void drive(bool ce,bool sclk,bool data){access(4,true,(pins&0xecffffff)|(uint32_t(ce)<<24)|(uint32_t(sclk)<<25)|(uint32_t(data)<<28));}
    void begin(){drive(false,false,false);drive(true,false,false);}
    void end(){drive(false,false,false);}
    void send(uint8_t b){for(unsigned i=0;i<8;i++){drive(true,false,(b>>i)&1);drive(true,true,(b>>i)&1);drive(true,false,(b>>i)&1);}}
    uint8_t receive(bool compare=true){
        uint8_t b=(access(8,false,0,15,compare)>>28)&1;
        for(unsigned i=1;i<8;i++){drive(true,true,false);drive(true,false,false);b|=((access(8,false,0,15,compare)>>28)&1)<<i;}
        return b;
    }
    void write(uint8_t cmd,uint8_t data){begin();send(cmd);send(data);end();}
    uint8_t read(uint8_t cmd,bool compare=true){begin();send(cmd);uint8_t r=receive(compare);end();return r;}
    void burst_write(uint8_t cmd,const std::vector<uint8_t>& bytes){begin();send(cmd);for(auto b:bytes)send(b);end();}
    std::vector<uint8_t> burst_read(uint8_t cmd,unsigned n,bool compare=true){
        begin();send(cmd);std::vector<uint8_t> bytes;
        for(unsigned i=0;i<n;i++){
            if(i){drive(true,true,false);drive(true,false,false);}
            bytes.push_back(receive(compare));
        }
        end();return bytes;
    }
};
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Bench b;b.reset();
        check(b.access(4)==0,"initial GPIO latch");
        b.access(4,true,0x80008000);check(b.access(4)==0x80008000,"BIOS pin pattern");
        b.access(4,true,0x1234,3);check(b.access(4)==0x80001234,"GPIO independent byte lanes");b.access(4,true,0);
        for(unsigned a=0;a<31;a++){uint8_t v=(a*17)^0xa5;b.write(0xc0|(a<<1),v);check(b.read(0xc1|(a<<1))==v,"all RAM addresses");}
        std::vector<uint8_t> ram(31);for(unsigned i=0;i<31;i++)ram[i]=0x73+i*3;
        b.burst_write(0xfe,ram);check(b.burst_read(0xff,31)==ram,"RAM burst31");
        // CLOCK HALT keeps the common serial oracle comparisons deterministic.
        const std::vector<uint8_t> clock={0x92,0x34,0x23,0x28,0x02,0x07,0x24,0};
        b.burst_write(0xbe,clock);check(b.burst_read(0xbf,8)==clock,"clock burst8 common MAME bytes");
        b.write(0x90,0xa9);check(b.read(0x91)==0xa9,"trickle register readback");
        b.write(0x8e,0x80);b.write(0xc0,0xff);check(b.read(0xc1)==ram[0],"write protection RAM");
        b.write(0x82,0x11);check(b.read(0x83)==0x34,"write protection calendar");
        // Datasheet permits single-byte control writes to clear WP; MAME does not.
        b.write(0x8e,0);check(b.state(7)==0,"clear WP through control");b.oracle.m_reg[7]=0;
        b.write(0xc0,0xf1);check(b.read(0xc1)==0xf1,"RAM resumes after WP clear");
        // An incomplete clock burst must not update the calendar.
        auto before=std::array<uint8_t,8>{};for(unsigned i=0;i<8;i++)before[i]=b.state(i);
        b.burst_write(0xbe,{0x81,0x02,0x03});for(unsigned i=0;i<8;i++)check(b.state(i)==before[i],"partial clock burst atomicity");
        for(unsigned i=0;i<9;i++)b.oracle.m_reg[i]=b.state(i);
        b.burst_write(0xbe,{0x91,0x10,0x22,0x01,0x03,0x01,0x26,0x80});
        check(b.state(0)==0x91&&b.state(7)==0x80,"complete clock burst applies WP last");
        b.burst_write(0xbe,{0x80,0,0,1,1,1,0,0});check(b.state(0)==0x91&&b.state(7)==0x80,"protected burst cannot clear WP");
        b.write(0x8e,0);b.oracle.m_reg[7]=0;
        auto repeated=b.burst_read(0xc1,3,false);check(repeated==std::vector<uint8_t>({0xf1,0xf1,0xf1}),"continuous single-byte read");
        auto repeated_ram=b.burst_read(0xff,62,false);for(unsigned i=0;i<62;i++)check(repeated_ram[i]==b.state(9+i%31),"continuous RAM burst wraps31");
        // Invalid command and CE termination must not create an unintended store.
        auto old=b.state(9);b.write(0x40,0xa5);check(b.state(9)==old,"invalid command ignored");
        b.begin();b.send(0xc0);b.drive(true,true,true);b.end();check(b.state(9)==old,"incomplete byte aborted");
        b.d.reset=1;b.tick();b.d.reset=0;check(b.state(9)==old&&b.state(0)==0x91,"warm reset preserves battery state");
        b.pins=0;b.oracle=ds1302_device{};for(unsigned i=0;i<9;i++)b.oracle.m_reg[i]=b.state(i);
        // Physical timekeeping at the accelerated compile-time 64-clock second.
        struct Calendar {std::array<uint8_t,7> start,expected;};
        const std::vector<Calendar> cases={
            {{0x59,0x59,0x23,0x31,0x01,0x07,0x26},{0,0,0,1,2,1,0x26}},
            {{0x59,0x59,0x23,0x28,0x02,0x02,0x24},{0,0,0,0x29,2,3,0x24}},
            {{0x59,0x59,0x23,0x29,0x02,0x03,0x24},{0,0,0,1,3,4,0x24}},
            {{0x59,0x59,0x23,0x28,0x02,0x02,0x25},{0,0,0,1,3,3,0x25}},
            {{0x59,0x59,0x23,0x30,0x04,0x06,0x26},{0,0,0,1,5,7,0x26}},
            {{0x59,0x59,0x23,0x31,0x12,0x07,0x99},{0,0,0,1,1,1,0}},
            {{0x59,0x59,0x91,0x04,0x10,0x01,0x26},{0,0,0xb2,4,0x10,1,0x26}},
            {{0x59,0x59,0xb1,0x04,0x10,0x01,0x26},{0,0,0x92,5,0x10,2,0x26}},
            {{0x59,0x59,0x92,0x04,0x10,0x01,0x26},{0,0,0x81,4,0x10,1,0x26}}
        };
        for(auto c:cases){b.seed(c.start);for(unsigned i=0;i<63;i++)b.tick();check(b.state(0)==c.start[0],"RTC period no early tick");b.tick();for(unsigned i=0;i<7;i++)check(b.state(i)==c.expected[i],"calendar/12h rollover");}
        b.seed({0x80,0,0,1,1,7,0});for(unsigned i=0;i<200;i++)b.tick();check(b.state(0)==0x80,"clock halt");
        b.seed({0x59,0,0,1,1,7,0});auto snapshot=b.burst_read(0xbf,8,false);
        check(snapshot[0]==0x59&&snapshot[1]==0,"coherent clock burst across tick");check(b.state(1)==1,"RTC advances during burst");
        b.seed({0x80,0,0,1,1,7,0});b.d.state_address=39;b.d.restore_data=0x5a;b.d.restore_valid=1;b.tick();b.d.restore_valid=0;
        check(b.state(39)==0x5a,"last battery RAM restore byte");
        // Replay real game pin transactions against MAME with a deterministic,
        // halted seed. Captured wall-clock data bits are not asserted as this seed.
        b.reset();unsigned replay_rows=0;
        std::ifstream input("sim/obj_dir/rtc_reference/gpio.csv");check(bool(input),"missing game GPIO fixture");
        std::string line;std::getline(input,line);
        while(std::getline(input,line)){
            std::stringstream s(line);std::vector<std::string> c;std::string x;while(std::getline(s,x,','))c.push_back(x);
            check(c.size()==7,"GPIO CSV shape");unsigned a=std::stoul(c[3],nullptr,16)&15,data=std::stoul(c[4],nullptr,16),mask=std::stoul(c[5],nullptr,16),strobe=0;
            for(unsigned i=0;i<4;i++)if((mask>>(8*i))&255)strobe|=1<<i;
            bool w=c[2]=="W";
            if(a==4&&!w)check(b.access(a)==data,"captured GPIO latch result");else b.access(a,w,data,strobe);
            ++replay_rows;
        }
        std::cout<<"PASS GPIO/DS1302: "<<checks<<" checks; RAM31, clock/burst/WP, atomic abort, 12h/leap/month/year, snapshot/halt/restore; "<<replay_rows<<" captured pin rows with deterministic MAME serial oracle; "<<b.clocks<<" clocks\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL GPIO/DS1302: "<<e.what()<<"\n";return 1;}
}
