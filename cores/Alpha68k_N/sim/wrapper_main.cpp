#include "Vemu.h"
#include "Vemu___024root.h"
#include "verilated.h"
#include "sdram_model.h"
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>

struct SdramPins {
    uint8_t sdram_cke,sdram_ncs,sdram_nras,sdram_ncas,sdram_nwe,sdram_ba,sdram_dqml,sdram_dqmh;
    uint16_t sdram_a,sdram_din;
    explicit SdramPins(const Vemu& t):sdram_cke(t.SDRAM_CKE),sdram_ncs(t.SDRAM_nCS),
        sdram_nras(t.SDRAM_nRAS),sdram_ncas(t.SDRAM_nCAS),sdram_nwe(t.SDRAM_nWE),
        sdram_ba(t.SDRAM_BA),sdram_dqml(t.SDRAM_DQML),sdram_dqmh(t.SDRAM_DQMH),
        sdram_a(t.SDRAM_A),sdram_din(t.SIM_SDRAM_DIN) {}
};

int main(int argc,char** argv) try {
    if(argc!=4 && argc!=5) return 2;
    bool host_only=argc==5 && std::string(argv[4])=="--host-only";
    bool protocol_only=argc==5 && std::string(argv[4])=="--protocol-only";
    bool features=protocol_only || (argc==5 && std::string(argv[4])=="--features");
    if(argc==5 && !host_only && !features) return 2;
    std::ifstream file(argv[1],std::ios::binary);
    std::vector<uint8_t> rom{std::istreambuf_iterator<char>(file),{}};
    if(rom.size()!=0xa0000) throw std::runtime_error("unexpected packed ROM length");
    unsigned requested=std::stoul(argv[2]);
    if(!requested || (features && requested<6)) throw std::runtime_error("wrapper protocol needs six complete fields");
    const std::filesystem::path output=argv[3];std::filesystem::create_directories(output);
    std::ofstream frames(output/"frames.csv");
    frames<<"frame,core_pixels,vga_pixels,duplicates,main_transactions,unmapped,deadlines,overflows,worst_line\n";
    Vemu top;Sdram device;
    top.SIM_MASTER=0;top.SIM_SDRAM=0;top.SIM_LOCKED=0;top.RESET=1;
    top.SIM_TEST_HS_ACCESS=0;top.SIM_TEST_HS_WRITE=0;top.SIM_TEST_HS_ADDR=0;top.SIM_TEST_HS_DATA=0;
    top.SIM_HPS_HOST=0;top.SDRAM_DQ=0;top.CLK_50M=0;top.CLK_AUDIO=0;
    top.HDMI_WIDTH=1920;top.HDMI_HEIGHT=1080;top.DDRAM_BUSY=0;
    top.DDRAM_DOUT=0;top.DDRAM_DOUT_READY=0;top.FB_VBL=0;top.FB_LL=0;
    top.FB_PAL_DIN=0;top.SD_MISO=0;top.SD_CD=0;top.USER_IN=0x7f;
    top.UART_CTS=0;top.UART_RXD=1;top.UART_DSR=0;top.OSD_STATUS=0;top.eval();
    // Establish reset-driven device pins before interpreting SDRAM commands,
    // exactly as the qualified board/system harness does. Verilator's initial
    // zero values are not a valid physical SDRAM command before these edges.
    for(unsigned i=0;i<2;i++) {
        top.SIM_MASTER=1;top.SIM_SDRAM=0;top.eval();
        top.SIM_MASTER=0;top.SIM_SDRAM=1;top.eval();
    }
    uint64_t ticks=0,half_edges=0,load_words=0,wait_ticks=0;
    unsigned frame=0,core_pixels=0,vga_pixels=0,duplicates=0;
    bool started=false,finished=false,checking_load=false;
    unsigned hs_requests=0;bool hs_req_last=false;
    std::vector<uint8_t> core(256*224*3),vga,covered(256*224);
    vga.reserve(384*264*3);
    auto save=[&](const char* kind,const std::vector<uint8_t>& image) {
        char name[80];std::snprintf(name,sizeof name,"frame_%06u.%s.rgb",frame,kind);
        std::ofstream f(output/name,std::ios::binary);f.write(reinterpret_cast<const char*>(image.data()),image.size());
    };
    auto tick=[&]() {
        bool boundary=started && top.SIM_RAW_CE && top.SIM_RAW_X==383 && top.SIM_RAW_Y==239;
        if(checking_load && top.SIM_LOAD_WR) {
            unsigned address=top.SIM_LOAD_ADDR;
            if(address!=load_words*2 || address+1>=rom.size()
                || top.SIM_LOAD_DATA!=(rom[address]|(unsigned(rom[address+1])<<8)))
                throw std::runtime_error("HPS transport word/address divergence at word "+std::to_string(load_words));
            load_words++;
        }
        // 1 ps quantization of ideal 48 MHz: three half-edges total 31,250 ps.
        // The separate reference/lock dynamics and physical setup/hold remain
        // outside this functional model; the production PLL stays unchanged.
        auto half=[&]() {Verilated::timeInc(half_edges++%3==0?10416:10417);};
        half();top.SIM_MASTER=0;top.SIM_SDRAM=1;top.eval();
        SdramPins pins(top);device.sample(pins);top.SDRAM_DQ=device.dq;top.eval();
        half();top.SIM_MASTER=1;top.SIM_SDRAM=0;top.eval();ticks++;
        if(top.SIM_HS_REQUEST && !hs_req_last) hs_requests++;
        hs_req_last=top.SIM_HS_REQUEST;
        if(!started && !top.SIM_GAME_RESET) {
            started=true;
            std::cout<<"ROM released through real HPS: words="<<load_words<<" ticks="<<ticks<<std::endl;
        }
        if(started && !finished) {
            if(top.SIM_VIDEO_CE && !top.SIM_VIDEO_HB && !top.SIM_VIDEO_VB) {
                unsigned x=top.SIM_VIDEO_X,y=top.SIM_VIDEO_Y;
                if(y<16 || y>=240) throw std::runtime_error("core visible coordinate out of bounds");
                unsigned index=(y-16)*256+x;duplicates+=covered[index]++;core_pixels++;
                core[index*3]=top.SIM_VIDEO_RGB>>16;core[index*3+1]=top.SIM_VIDEO_RGB>>8;core[index*3+2]=top.SIM_VIDEO_RGB;
            }
            if(top.CE_PIXEL && top.VGA_DE) {
                if(vga_pixels>=384*264) throw std::runtime_error("framework field pixel overflow at field "+std::to_string(frame));
                // Preserve all actual startup output samples. The pinned
                // framework measures sync polarity during its first fields;
                // qualify the same four-field settling window as the real
                // framework fixture, without padding/truncating RGB captures.
                vga.push_back(top.VGA_R);vga.push_back(top.VGA_G);vga.push_back(top.VGA_B);vga_pixels++;
            }
            if(boundary) {
                frames<<frame<<','<<core_pixels<<','<<vga_pixels<<','<<duplicates<<','<<top.SIM_MAIN_TX
                    <<','<<top.SIM_UNMAPPED<<','<<top.SIM_DEADLINES<<','<<top.SIM_OVERFLOWS<<','<<top.SIM_WORST_LINE<<'\n';frames.flush();
                if(core_pixels!=256*224 || duplicates || top.SIM_UNMAPPED || top.SIM_DEADLINES || top.SIM_OVERFLOWS)
                    throw std::runtime_error("real wrapped core coverage/bus/deadline failure");
                if(frame>=4 && (vga_pixels!=256*224 || core!=vga))
                    throw std::runtime_error("framework RGB/coverage divergence at field "+std::to_string(frame));
                if(frame==0 || frame%30==0 || frame+1==requested) {save("core",core);save("vga",vga);}
                if(frame<8 || frame%30==0 || frame+1==requested)
                    std::cout<<"frame="<<frame<<" core="<<core_pixels<<" vga="<<vga_pixels
                        <<" main="<<top.SIM_MAIN_TX<<" misses="<<top.SIM_DEADLINES<<std::endl;
                frame++;finished=frame==requested;core_pixels=vga_pixels=duplicates=0;
                std::fill(core.begin(),core.end(),0);vga.clear();std::fill(covered.begin(),covered.end(),0);
            }
        }
    };
    for(unsigned i=0;i<20;i++) tick();
    top.SIM_LOCKED=1;top.RESET=0;
    for(unsigned i=0;i<20000;i++) tick();
    if(top.SIM_COLD_RESET || !top.SIM_GAME_RESET) throw std::runtime_error("wrapper power/load reset contract failed");
    auto word=[&](bool file_port,uint16_t value) {
        // HPS strobe is one master edge; its data and enable remain stable.
        top.SIM_HPS_HOST=(uint64_t(value)<<16)|(uint64_t(1)<<33)|(uint64_t(1)<<(file_port?35:34));tick();
        top.SIM_HPS_HOST=(uint64_t(value)<<16)|(uint64_t(1)<<(file_port?35:34));
        for(unsigned i=0;i<3;i++) tick();
    };
    auto end=[&]() {top.SIM_HPS_HOST=0;for(unsigned i=0;i<3;i++) tick();};
    auto user=[&](uint16_t cmd,const std::vector<uint16_t>& data) {word(false,cmd);for(auto v:data) word(false,v);end();};
    user(0x02,{0xffff,0});user(0x03,{0xffff,0});
    if(top.SIM_CONTROLS!=0xbfbf || top.SIM_COINS!=0) throw std::runtime_error("real HPS joystick/start/coin mapping failed");
    user(0x02,{0,0});user(0x03,{0,0});
    if(top.SIM_CONTROLS || top.SIM_COINS!=3) throw std::runtime_error("HPS joystick release failed");
    user(0x1e,{2,0,0,0,0,0,0,0});
    for(unsigned i=0;i<100;i++) tick();
    if(top.VIDEO_ARX!=4 || top.VIDEO_ARY!=3) throw std::runtime_error("HPS orientation/aspect status failed");
    if(top.SIM_DIPS!=0x8e) throw std::runtime_error("DIP power-on defaults failed");
    word(true,0x55);word(true,254);end();
    word(true,0x53);word(true,1);word(true,0);word(true,0);end();
    word(true,0x54);word(true,0);word(true,0xbeef);end();
    word(true,0x53);word(true,0);end();
    if(top.SIM_DIPS!=0) throw std::runtime_error("HPS DIP bank-zero/address isolation failed");
    word(true,0x53);word(true,1);word(true,0);word(true,0);end();
    word(true,0x54);word(true,0xa58e);end();
    word(true,0x53);word(true,0);end();
    if(top.SIM_DIPS!=0x8e) throw std::runtime_error("HPS DIP low-byte restore failed");
    if(host_only) {
        if(!top.SIM_GAME_RESET || top.SIM_ROM_LOADED || load_words)
            throw std::runtime_error("DIP transfer changed the ROM/CPU reset gate");
        std::ofstream result(output/"result.json");
        result<<"{\"scope\":\"real HPS controls/status/DIP transport while game held in reset\",\"passed\":true,\"dips\":142,\"rom_loaded\":false}\n";
        top.final();return 0;
    }
    word(true,0x55);word(true,0);end();
    word(true,0x53);word(true,1);word(true,0);word(true,0);end();
    checking_load=true;word(true,0x54);
    for(unsigned i=0;i<rom.size();i++) {
        while(top.SIM_IOCTL_WAIT) {if(++wait_ticks>10000000) throw std::runtime_error("HPS ioctl backpressure timeout");tick();}
        word(true,rom[i]);
    }
    end();word(true,0x53);word(true,0);end();
    checking_load=false;
    if(load_words!=rom.size()/2) throw std::runtime_error("HPS incomplete ROM transfer");
    for(unsigned i=0;!started;i++) {if(i==200000) throw std::runtime_error("ROM release/FIFO drain timeout");tick();}
    while(!finished) tick();
    if(top.FB_EN || top.DDRAM_WE) throw std::runtime_error("horizontal wrapper unexpectedly writes framebuffer");
    if(features) {
        auto idle=[&](unsigned n) {for(unsigned i=0;i<n;i++) tick();};
        auto status=[&](uint32_t value) {user(0x1e,{uint16_t(value),uint16_t(value>>16),0,0,0,0,0,0});idle(100);};
        auto download=[&](unsigned index,const std::vector<uint8_t>& bytes) {
            word(true,0x55);word(true,index);end();
            word(true,0x53);word(true,1);word(true,0);word(true,0);end();
            word(true,0x54);for(auto b:bytes) word(true,b);end();
            word(true,0x53);word(true,0);end();
        };
        // Exhaustive real HPS DIP transport; the MRA check separately proves
        // per-game field names, encodings/defaults and full eight-bit coverage.
        for(unsigned value=0;value<256;value++) {
            download(254,{uint8_t(value)});
            if(top.SIM_DIPS!=value) throw std::runtime_error("DIP bank exhaustive mismatch");
        }
        download(254,{0x8e});
        // Exercise the real HPS credits trigger and OSD dismissal without pausing.
        user(0x1e,{2,0,0,0,0,0,0,0x100});idle(811008+32);
        if(!top.rootp->emu__DOT__credits__DOT__active) throw std::runtime_error("HPS credits trigger did not open overlay");
        status(2);auto running_tx=top.SIM_MAIN_TX;auto osd_requests=hs_requests;
        top.OSD_STATUS=1;idle(811008+32);
        if(top.rootp->emu__DOT__credits__DOT__active || top.SIM_PAUSED || top.SIM_USER_PAUSE
           || top.SIM_MAIN_TX==running_tx || hs_requests!=osd_requests)
            throw std::runtime_error("OSD must dismiss credits and leave guest running without save");
        top.OSD_STATUS=0;idle(100);
        user(0x02,{0x100,0});std::cout<<"pause high joy="<<top.SIM_JOY0<<" user="<<unsigned(top.SIM_USER_PAUSE)<<" reset="<<unsigned(top.SIM_GAME_RESET)<<std::endl;user(0x02,{0,0});idle(10);
        if(!top.SIM_PAUSED) throw std::runtime_error("pause button toggle failed user="+std::to_string(top.SIM_USER_PAUSE)+" joy="+std::to_string(top.SIM_JOY0));
        auto tx=top.SIM_MAIN_TX;auto x=top.SIM_RAW_X;
        idle(10000);
        if(top.SIM_MAIN_TX!=tx || top.SIM_RAW_X==x) throw std::runtime_error("pause bus/raster isolation failed");
        std::ifstream cfgfile(std::filesystem::path(argv[1]).parent_path()/"hiscore_config.bin",std::ios::binary);
        std::vector<uint8_t> cfg{std::istreambuf_iterator<char>(cfgfile),{}};
        if(cfg.size()!=32) throw std::runtime_error("two-entry hiscore fixture config missing");
        top.OSD_STATUS=1;idle(10);
        download(3,cfg);if(!top.SIM_HS_CONFIGURED) throw std::runtime_error("real HPS hiscore config failed");
        auto ram=[&](unsigned address,bool write,uint8_t data) {
            top.SIM_TEST_HS_ACCESS=1;top.SIM_TEST_HS_WRITE=write;
            top.SIM_TEST_HS_ADDR=address;top.SIM_TEST_HS_DATA=data;idle(3);
            auto value=top.SIM_HS_DATA;top.SIM_TEST_HS_ACCESS=0;top.SIM_TEST_HS_WRITE=0;return value;
        };
        std::vector<unsigned> addresses;
        for(unsigned i=16;i<cfg.size();i+=8) {
            unsigned a=(unsigned(cfg[i])<<24)|(unsigned(cfg[i+1])<<16)|(unsigned(cfg[i+2])<<8)|cfg[i+3];
            for(unsigned b=0;b<cfg[i+4];b++) {
                addresses.push_back(a+b);ram(a+b,true,b==0 ? cfg[i+5] : b+1==cfg[i+4] ? cfg[i+6] : 0);
            }
        }
        // Known test score payload, not an earned-gameplay-score claim. It
        // deliberately changes the readiness signatures after initial load.
        std::vector<uint8_t> scores(addresses.size());
        for(unsigned i=0;i<scores.size();i++) scores[i]=uint8_t(i*37+19);
        download(4,scores);
        top.OSD_STATUS=1;status(3);
        if(top.rootp->emu__DOT__credits__DOT__active || top.SIM_USER_PAUSE)
            throw std::runtime_error("reset must clear credits and manual pause");
        idle(20);status(2);
        // The synthetic readiness fixture must stay protected by manual Pause.
        // OSD now leaves the guest running; it cannot protect these test bytes.
        user(0x02,{0x100,0});user(0x02,{0,0});idle(50000);
        if(!top.SIM_USER_PAUSE || !top.SIM_PAUSED)
            throw std::runtime_error("synthetic restore fixture lost manual pause");
        for(unsigned i=0;i<addresses.size();i++) {
            unsigned actual=ram(addresses[i],false,0);
            if(actual!=scores[i]) throw std::runtime_error("hiscore restore/endian mismatch at "+std::to_string(i)
                +" actual="+std::to_string(actual)+" expected="+std::to_string(scores[i])
                +" state="+std::to_string(top.SIM_HS_STATE)+" paused="+std::to_string(top.SIM_PAUSED)
                +" restoring="+std::to_string(top.SIM_HS_RESTORING));
        }
        // Explicitly release manual Pause before the next fresh save-trigger edge.
        top.OSD_STATUS=0;user(0x02,{0x100,0});user(0x02,{0,0});idle(100);
        // Keep the actual CPUs paused while simulating an altered score byte.
        user(0x02,{0x100,0});user(0x02,{0,0});idle(10000);
        if(!top.SIM_USER_PAUSE || !top.SIM_PAUSED) throw std::runtime_error("manual pause did not settle before score fixture");
        scores[5]^=0x5a;ram(addresses[5],true,scores[5]);
        top.OSD_STATUS=0;idle(20);unsigned prior_requests=hs_requests;auto paused_tx=top.SIM_MAIN_TX;
        top.OSD_STATUS=1;idle(10000);
        if(hs_requests!=prior_requests || top.SIM_MAIN_TX!=paused_tx)
            throw std::runtime_error("OSD opening must neither extract scores nor resume a manually paused CPU");
        top.OSD_STATUS=0;user(0x02,{0x100,0});user(0x02,{0,0});idle(100);
        if(top.SIM_USER_PAUSE || top.SIM_PAUSED) throw std::runtime_error("manual pause release failed");
        prior_requests=hs_requests;
        user(0x02,{0x100,0});user(0x02,{0,0});idle(10000);
        if(hs_requests!=prior_requests+1) throw std::runtime_error("manual-pause autosave request missing prior="+std::to_string(prior_requests)+" current="+std::to_string(hs_requests)+" state="+std::to_string(top.SIM_HS_STATE)+" restore="+std::to_string(top.SIM_HS_RESTORING)+" extract="+std::to_string(top.SIM_HS_EXTRACTING));
        word(true,0x55);word(true,4);end();
        word(true,0x53);word(true,0xaa);word(true,0);word(true,0);end();idle(20);
        word(true,0x54);
        for(unsigned i=0;i<scores.size();i++) {
            word(true,0);unsigned b=top.HPS_BUS & 0xff;
            if(b!=scores[i]) throw std::runtime_error("HPS saved-byte mismatch at "+std::to_string(i)+" got "+std::to_string(b)+" expected "+std::to_string(scores[i]));
        }
        end();word(true,0x53);word(true,0);end();
        top.OSD_STATUS=0;user(0x02,{0x100,0});user(0x02,{0,0});idle(100);
        prior_requests=hs_requests;
        user(0x02,{0x100,0});user(0x02,{0,0});idle(10000);
        if(hs_requests!=prior_requests) throw std::runtime_error("unchanged manual-pause autosave retriggered");
        if(protocol_only) {
            std::ofstream protocol_result(output/"features.json");
            protocol_result<<"{\"passed\":true,\"dip_values\":256,\"hiscore_bytes\":"<<scores.size()
                <<",\"credits_real_HPS_trigger\":true,\"credits_OSD_dismissal\":true,\"OSD_game_continues\":true,\"OSD_no_save\":true,\"manual_pause_bus_frozen\":true,\"manual_pause_changed_upload\":true,\"manual_pause_unchanged_no_upload\":true,\"reset_clears_user_pause\":true,\"limit\":\"Synthetic score protocol fixture; no earned-gameplay or physical-output claim\"}\n";
        } else {
        // Verify uniform native clock enables and frame/line periods while
        // CPUs are paused. Mode changes are allowed a four-field settle.
        auto raster=[&](uint32_t mode,bool direct,unsigned pixel_period,bool retimed=false) {
            status(mode);user(0x01,{uint16_t(direct ? 0x400 : 0)});
            if(bool(top.SIM_DIRECT_VIDEO)!=direct) throw std::runtime_error("direct-video HPS command failed");
            idle(4*811008);uint64_t hs_edge=0,vs_edge=0,ce_edge=0;
            bool old_hs=top.VGA_HS,old_vs=top.VGA_VS;unsigned lines=0,fields=0,pixels=0;
            for(unsigned i=0;i<3*811008;i++) {
                tick();
                if(old_hs && !top.VGA_HS) {
                    if(hs_edge && !retimed && ticks-hs_edge!=3072) throw std::runtime_error("HSync cadence changed");
                    hs_edge=ticks;lines++;
                }
                if(old_vs && !top.VGA_VS) {
                    if(vs_edge && (retimed ? (ticks-vs_edge<810980 || ticks-vs_edge>811036) : ticks-vs_edge!=811008)) throw std::runtime_error("refresh period changed");
                    vs_edge=ticks;fields++;
                }
                if(top.CE_PIXEL && top.VGA_DE) {
                    if(ce_edge && !retimed && ticks-ce_edge<20 && ticks-ce_edge!=pixel_period) throw std::runtime_error("nonuniform active pixel enable gap="+std::to_string(ticks-ce_edge)+" expected="+std::to_string(pixel_period)+" hs="+std::to_string(top.VGA_HS)+" rawx="+std::to_string(top.SIM_RAW_X)+" mode="+std::to_string(mode));
                    ce_edge=ticks;pixels++;
                } else if(!top.VGA_DE) ce_edge=0;
                old_hs=top.VGA_HS;old_vs=top.VGA_VS;
            }
            if(lines<750 || fields<2 || pixels==0) throw std::runtime_error("CRT output lost picture/sync");
            std::cout<<"video mode="<<mode<<" direct="<<direct<<" lines="<<lines<<" fields="<<fields<<" pixels="<<pixels<<std::endl;
        };
        auto image=[&]() {
            std::vector<uint8_t> pixels(256*224*3);std::vector<bool> seen(256*224);
            idle(811008);
            for(unsigned i=0;i<811008;i++) {
                tick();if(top.SIM_VIDEO_CE && !top.SIM_VIDEO_HB && !top.SIM_VIDEO_VB) {
                    unsigned at=(top.SIM_VIDEO_Y-16)*256+top.SIM_VIDEO_X;
                    pixels[at*3]=top.SIM_VIDEO_RGB>>16;pixels[at*3+1]=top.SIM_VIDEO_RGB>>8;pixels[at*3+2]=top.SIM_VIDEO_RGB;seen[at]=true;
                }
            }
            if(std::find(seen.begin(),seen.end(),false)!=seen.end()) throw std::runtime_error("rotation raw-image coverage failed");
            return pixels;
        };
        status(2);auto native_image=image();status(2|128);auto flipped_image=image();
        for(unsigned i=0;i<256*224;i++) for(unsigned channel=0;channel<3;channel++)
            if(flipped_image[i*3+channel]!=native_image[(256*224-1-i)*3+channel])
                throw std::runtime_error("native renderer 180-degree pixel mismatch");
        for(unsigned mode=1;mode<=4;mode++) {
            user(0x01,{0});status(2|(mode<<8));idle(3*811008);
            unsigned width=top.VIDEO_ARX&4095,height=top.VIDEO_ARY&4095;
            if(!(top.VIDEO_ARX&4096) || !(top.VIDEO_ARY&4096) || height!=896 || !width || width>1920 || (mode>1 && width%256))
                throw std::runtime_error("integer scaling geometry failed for mode "+std::to_string(mode)+" "+std::to_string(width)+"x"+std::to_string(height));
            std::cout<<"integer scale="<<mode<<" size="<<width<<"x"<<height<<std::endl;
        }
        raster(2,true,8);
        raster(2|(1u<<11)|(1u<<12)|(1u<<15)|(1u<<20),true,9);
        raster(2|(1u<<11)|(4u<<12)|(31u<<15)|(31u<<20),true,7);
        raster(2|(1u<<11)|(1u<<25),false,8,true);
        raster(2|(1u<<11)|(6u<<25),false,8,true);
        // Native quarter-turn writer is real screen_rotate with ideal DDR
        // availability; Main/scaler display and physical DDR are not modeled.
        for(unsigned ccw=0;ccw<2;ccw++) {
            status(ccw<<6);idle(5*811008);
            if(!top.FB_EN || top.FB_WIDTH!=224 || top.FB_HEIGHT!=256)
                throw std::runtime_error("quarter-turn framebuffer dimensions failed");
            unsigned writes=0;std::vector<bool> mapped(256*224);
            for(unsigned i=0;i<811008;i++) {
                tick();if(top.DDRAM_WE) {
                    writes++;unsigned offset=((top.DDRAM_ADDR&0xfffff)<<3)+(top.DDRAM_BE==0xf0 ? 4 : 0);
                    unsigned ox=(offset%top.FB_STRIDE)/4,oy=offset/top.FB_STRIDE;
                    if(ox>=224 || oy>=256) throw std::runtime_error("quarter-turn address outside frame");
                    unsigned sx=ccw ? 255-oy : oy,sy=ccw ? ox : 223-ox;
                    unsigned source=(sy*256+sx)*3;uint32_t pixel=top.DDRAM_DIN;
                    if(uint8_t(pixel)!=native_image[source] || uint8_t(pixel>>8)!=native_image[source+1] || uint8_t(pixel>>16)!=native_image[source+2])
                        throw std::runtime_error("quarter-turn framebuffer pixel/address mismatch");
                    mapped[oy*224+ox]=true;
                }
            }
            if(writes!=256*224 || std::find(mapped.begin(),mapped.end(),false)!=mapped.end()) throw std::runtime_error("rotation framebuffer coverage failed");
        }
        user(0x01,{0x400});idle(4*811008);
        if(top.FB_EN || top.DDRAM_WE) throw std::runtime_error("direct video did not suppress rotation DDR writes");
        std::ofstream feature_result(output/"features.json");
        feature_result<<"{\"passed\":true,\"dip_values\":256,\"hiscore_bytes\":"<<scores.size()<<",\"pause_bus_frozen\":true,\"OSD_game_continues\":true,\"OSD_no_save\":true,\"manual_pause_changed_upload\":true,\"manual_pause_unchanged_no_upload\":true,\"crt_modes\":5,\"quarter_turn_modes\":2,\"quarter_turn_pixels_verified\":true,\"rotate180_pixels_verified\":true,\"integer_scale_modes\":4,\"native_line_master_cycles\":3072,\"native_frame_master_cycles\":811008,\"limit\":\"RAM protocol fixture uses explicit synthetic scores; earned-gameplay reload and physical outputs remain pending\"}\n";
        }
    }
    std::ofstream result(output/"result.json");
    result<<"{\"scope\":\"real emu/HPS/CPU/video/audio/SDRAM with ideal PLL and explicit framework scope adapter\","
        <<"\"frames\":"<<frame<<",\"framework_settling_fields\":4,\"profile\":"<<unsigned(top.SIM_PROFILE)
        <<",\"rom_words\":"<<load_words<<",\"wait_ticks\":"<<wait_ticks
        <<",\"main_transactions\":"<<top.SIM_MAIN_TX<<",\"unmapped\":"<<top.SIM_UNMAPPED
        <<",\"deadlines\":"<<top.SIM_DEADLINES<<",\"overflows\":"<<top.SIM_OVERFLOWS
        <<",\"device_writes\":"<<device.writes<<",\"device_reads\":"<<device.reads
        <<",\"refreshes\":"<<device.refreshes<<",\"passed\":true}\n";
    top.final();return 0;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
