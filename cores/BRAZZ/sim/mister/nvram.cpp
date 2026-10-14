// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_nvram.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void ck(bool b,const char*s){++checks;if(!b)throw std::runtime_error(s);}
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{Vcs_nvram d;auto tick=[&](){d.clk=0;d.eval();d.clk=1;d.eval();};
 auto bus=[&](unsigned a,bool w,unsigned data,unsigned lanes){d.cpu_valid=1;d.cpu_write=w;d.cpu_address=a;d.cpu_data=data;d.cpu_strobe=lanes;d.eval();ck(d.cpu_ready,"CPU ready");tick();ck(d.cpu_response,"SRAM response");d.cpu_valid=0;return d.cpu_result;};
 tick();for(unsigned a=0;a<16384;a++)ck(bus(a,false,0,0)==0,"SRAM all-zero default");
 bus(3,true,0x12345678,15);bus(3,true,0xaabbccdd,5);ck(bus(3,false,0,0)==0x12bb56dd&&d.dirty,"CPU lanes");d.reset=1;tick();d.reset=0;ck(bus(3,false,0,0)==0x12bb56dd&&d.dirty,"warm reset preserves SRAM/dirty");
 d.ioctl_download=1;d.ioctl_index=4;d.ioctl_wr=1;d.cpu_valid=1;d.eval();ck(!d.cpu_ready&&d.pause_cpu,"restore excludes CPU");d.cpu_valid=0;
 for(unsigned i=0;i<65536;i++){d.ioctl_addr=i;d.ioctl_dout=i^0xa5;tick();}d.ioctl_addr=65536;d.ioctl_dout=0;tick();d.ioctl_index=260;d.ioctl_addr=0;tick();d.ioctl_download=0;d.ioctl_wr=0;tick();
 for(unsigned a=0;a<16384;a++){unsigned value=0;for(unsigned j=0;j<4;j++)value|=(((a*4+j)^0xa5)&255)<<(8*j);ck(bus(a,false,0,0)==value,"restore bytes/range/index guards");}
 auto request=[&](){d.osd_open=0;tick();d.osd_open=1;tick();for(int i=0;i<6;i++)tick();ck(d.ioctl_upload_req&&d.pause_cpu,"OSD save request");};
 auto start=[&](){d.ioctl_index=4;d.ioctl_upload=1;d.ioctl_rd=0;d.ioctl_addr=0;tick();ck(!d.ioctl_upload_req&&d.pause_cpu,"HPS acknowledgement");};
 auto send=[&](unsigned a){d.ioctl_rd=0;d.ioctl_addr=a;tick();ck(d.ioctl_din==((a^0xa5)&255),"upload byte order");d.ioctl_rd=1;tick();};
 auto finish=[&](){d.ioctl_rd=0;d.ioctl_upload=0;tick();ck(!d.pause_cpu,"upload releases pause");};
 request();d.reset=1;tick();ck(d.ioctl_upload_req&&d.dirty,"reset retains pending save");d.reset=0;start();for(unsigned i=0;i<12;i++)send(i);finish();ck(d.dirty,"short upload remains dirty");
 request();start();send(1);for(unsigned i=0;i<65536;i++)send(i);finish();ck(d.dirty,"reordered upload remains dirty");
 request();start();for(unsigned i=0;i<65536;i++)send(i);finish();ck(!d.dirty,"complete upload clears dirty");d.osd_open=0;tick();d.osd_open=1;for(int i=0;i<10;i++)tick();ck(!d.ioctl_upload_req,"unchanged SRAM does not resave");
 std::cout<<"PASS NVRAM: "<<checks<<" checks; lanes, restore, OSD save, reset, cancellation/order\n";return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL NVRAM: "<<e.what()<<"\n";return 1;}
}
