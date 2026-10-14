// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vcs_mister_rom_loader.h"
#include "verilated.h"
#include <array>
#include <iostream>
#include <stdexcept>
#include <vector>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        // cart_banks=1: one 16 MiB bank then the 16-byte test BIOS (BIOS_BYTES=16), streamed in DDR3 order.
        const unsigned CART=1u<<24,TOTAL=CART+16;
        Vcs_mister_rom_loader d;std::vector<uint8_t> image(TOTAL);
        unsigned cycles=0,writes=0,flushes=0,due=0;bool held=false,fail_next=false,error_due=false;uint64_t token=0;uint32_t offset=0;unsigned target=0;
        auto check=[](bool ok,const char* why){if(!ok)throw std::runtime_error(why);};
        auto tick=[&](){
            ++cycles;d.clk=0;d.load_ready=cycles%4==0;d.load_done=due&&cycles==due;d.load_error=d.load_done&&error_due;d.eval();
            if(held)check(d.load_valid&&d.load_data==token&&d.load_offset==offset&&d.load_target==target,"loader token changed while stalled");
            bool accept=d.load_valid&&d.load_ready;
            if(d.load_valid){
                check(!d.rom_ready&&d.loading&&d.ioctl_wait,"ROM released before physical write completion");
                held=!d.load_ready;token=d.load_data;offset=d.load_offset;target=d.load_target;
            }else held=false;
            d.clk=1;d.eval();
            if(accept){
                check(!due&&(d.load_be==255||(d.load_be==0&&target==4&&offset==0)),"overlapping/partial loader beat");
                // Stream order = DDR3 order: cartridge first, then the BIOS.
                unsigned start=target==4?offset:CART+offset;
                check(start+8<=image.size(),"loader target/bounds");
                if(d.load_be==0)++flushes;
                else{for(unsigned b=0;b<8;b++)image[start+b]=token>>(b*8);++writes;}due=cycles+3+cycles%7;error_due=fail_next;fail_next=false;
            }
            if(d.load_done)due=0;
        };
        d.cart_banks=1;d.reset=1;d.ioctl_download=0;d.ioctl_wr=0;d.ioctl_index=0;tick();tick();d.reset=0;
        auto byte=[&](unsigned a,uint8_t v){
            while(d.ioctl_wait)tick();d.ioctl_addr=a;d.ioctl_dout=v;d.ioctl_wr=1;tick();d.ioctl_wr=0;
        };
        auto end=[&](){while(d.ioctl_wait)tick();d.ioctl_download=0;tick();tick();tick();};
        d.ioctl_download=1;
        for(unsigned a=0;a<TOTAL;a++)byte(a,uint8_t(a*17+3));end();
        check(d.rom_ready&&!d.error&&!d.loading&&writes==TOTAL/8,"complete stream not committed");
        for(unsigned a=0;a<TOTAL;a++)check(image[a]==uint8_t(a*17+3),"BIOS/cartridge packing mismatch");
        // Reload revokes the old image before a single new byte is committed.
        d.ioctl_download=1;byte(0,99);check(!d.rom_ready,"reload retained stale ready");end();
        check(d.error&&!d.rom_ready,"truncated image accepted");
        // Address hole and unselected transfer cannot release the board.
        d.ioctl_download=1;byte(0,12);byte(2,34);end();check(d.error&&!d.rom_ready,"noncontiguous image accepted");
        d.ioctl_index=254;d.ioctl_download=1;tick();d.ioctl_wr=1;tick();d.ioctl_wr=0;d.ioctl_download=0;tick();
        check(!d.rom_ready,"DIP stream became a ROM");
        // Actual backend failure is sticky even with a complete host image.
        d.ioctl_index=0;d.ioctl_download=1;fail_next=true;
        for(unsigned a=0;a<TOTAL;a++)byte(a,uint8_t(a));end();
        check(d.error&&!d.rom_ready,"physical loader error accepted");
        // A complete recovery stream clears the prior error and waits each beat.
        d.ioctl_index=0;d.ioctl_download=1;for(unsigned a=0;a<TOTAL;a++)byte(a,uint8_t(255-a));end();
        check(d.rom_ready&&!d.error&&writes==3*(TOTAL/8),"complete reload recovery failed");
        for(unsigned a=0;a<TOTAL;a++)check(image[a]==uint8_t(255-a),"reload data mismatch");
        // Direct DDR3 mode: Main_MiSTer announces the length in ioctl_addr and sends no bytes.
        auto direct=[&](unsigned size){d.ioctl_index=0;d.ioctl_addr=0;d.ioctl_download=1;tick();d.ioctl_addr=size;tick();tick();
            check(!d.rom_ready&&d.loading,"direct load released early");d.ioctl_addr=size+1;d.ioctl_download=0;
            for(unsigned i=0;i<40;i++)tick();};
        unsigned before=writes;direct(TOTAL);
        check(d.rom_ready&&!d.error&&!d.loading&&flushes==1&&writes==before,"direct DDR3 image not accepted with one line-buffer flush");
        direct(TOTAL-1);check(d.error&&!d.rom_ready,"direct DDR3 image with wrong size accepted");
        direct(TOTAL);check(d.rom_ready&&!d.error&&flushes==2,"direct DDR3 reload recovery failed");
        // Board record bank count sets the expected size: 3 (crysking/evosocc), 0 = legacy 3, 7 = 27-bit ioctl_addr limit.
        unsigned fl=flushes;
        for(unsigned banks:{3u,0u,7u}){unsigned size=(banks?banks:3u)*CART+16;d.cart_banks=banks;
            direct(size-8);check(d.error&&!d.rom_ready,"direct multi-bank image with wrong size accepted");
            direct(CART*1+16);check(d.error&&!d.rom_ready,"direct image with another game's bank count accepted");
            direct(size);check(d.rom_ready&&!d.error&&flushes==++fl,"direct multi-bank image not accepted");}
        std::cout<<"PASS MiSTer ROM loader: direct DDR3 announce (exact size for 1/3/legacy/7 banks, flush, wrong-size reject, reload); 16 MiB cart + BIOS byte packing, delayed 64-bit writes, stable wait tokens, incomplete/reordered/DIP rejection and reload recovery\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL MiSTer ROM loader: "<<e.what()<<"\n";return 1;}
}
