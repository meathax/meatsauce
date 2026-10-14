// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <stdexcept>
#include <vector>
// Pin-level 32 MiB x16 SDR SDRAM, CL2/sequential BL2, 85.90908 MHz.
// Called on external SDRAM rising edges; never reads a request-port shortcut.
// MiSTer SDRAM modules take the chips' byte masks from address lines A12/A11
// (DQMH=A12, DQML=A11), as every MiSTer SDRAM controller drives them
// (e.g. MiSTer PSX rtl/sdram.sv: assign {SDRAM_DQMH,SDRAM_DQML}=SDRAM_A[12:11]).
// The separate DQM pins are ignored: masks must be carried on A12/A11 during
// WRITE data beats, and A12/A11 must be low two edges before every read beat.
struct SdramModel {
    std::vector<uint16_t> words=std::vector<uint16_t>(1u<<24,0);
    std::array<int,4> row{-1,-1,-1,-1};
    std::array<uint64_t,4> activated{},closed{},last_write{};
    struct Beat {uint64_t at;uint32_t index;};
    std::deque<Beat> read_beats;
    uint64_t cycle=0,blocked_until=0,refreshes=0,reads=0,writes=0;
    uint64_t last_refresh=0,max_refresh_gap=0;
    bool configured=false,write_tail=false;
    unsigned write_index=0,write_bank=0;
    uint16_t data=0;
    bool mister_dqm=std::getenv("CS_SDRAM_LEGACY_DQM")==nullptr;
    std::deque<std::pair<uint64_t,unsigned>> read_masks; // read DQM latency 2
    void check(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
    uint32_t index(unsigned bank,unsigned col){
        check(row[bank]>=0,"SDRAM column command to closed bank");
        return (uint32_t(row[bank])<<11)|(bank<<9)|(col&511);
    }
    void store(uint32_t i,uint16_t value,unsigned mask){
        if(!(mask&1))words[i]=(words[i]&0xff00)|(value&0xff);
        if(!(mask&2))words[i]=(words[i]&0xff)|(value&0xff00);
    }
    uint16_t tick(bool cke,bool cs,bool ras,bool cas,bool we,unsigned bank,
                  unsigned address,unsigned mask,uint16_t output,bool oe){
        ++cycle;
        if(mister_dqm)mask=(address>>11)&3;
        read_masks.push_back({cycle+2,mask});
        while(!read_masks.empty()&&read_masks.front().first<cycle)read_masks.pop_front();
        if(!read_beats.empty()&&read_beats.front().at==cycle){
            for(const auto& m:read_masks)if(m.first==cycle)check(m.second==0,"SDRAM read beat masked by DQM (A12/A11 high two edges earlier)");
            check(!oe,"SDRAM controller drives DQ during read beat");
            data=words[read_beats.front().index];read_beats.pop_front();
        }
        if(write_tail){
            check(oe,"SDRAM write continuation missing DQ drive");
            store(write_index,output,mask);last_write[write_bank]=cycle;write_tail=false;
        }
        if(!cke||cs)return data;
        unsigned command=(unsigned(ras)<<2)|(unsigned(cas)<<1)|unsigned(we);
        if(command==7)return data;
        check(cycle>=blocked_until,"SDRAM command violates tRFC/tMRD");
        switch(command){
        case 3:
            check(configured&&row[bank]<0,"SDRAM ACTIVATE to open/unconfigured bank");
            check(cycle>=closed[bank]+2,"SDRAM tRP violation");
            check(!activated[bank]||cycle>=activated[bank]+6,"SDRAM tRC violation");
            row[bank]=address&8191;activated[bank]=cycle;break;
        case 5:
            check(configured&&cycle>=activated[bank]+2,"SDRAM read tRCD violation");
            check(!(address&1024),"unexpected SDRAM auto-precharge");
            check(read_beats.empty()||read_beats.back().at<cycle+2,"overlapping SDRAM read bursts"); // seamless BL2 reads every 2 edges are legal
            read_beats.push_back({cycle+2,index(bank,address)});
            read_beats.push_back({cycle+3,index(bank,(address&~1u)|((address+1)&1u))});++reads;break;
        case 4:
            check(configured&&cycle>=activated[bank]+2,"SDRAM write tRCD violation");
            check(oe,"SDRAM WRITE missing DQ drive");
            check(!(address&1024),"unexpected SDRAM auto-precharge");
            store(index(bank,address),output,mask);last_write[bank]=cycle;
            write_index=index(bank,(address&~1u)|((address+1)&1u));
            write_bank=bank;write_tail=true;++writes;break;
        case 2:
            for(unsigned b=0;b<4;b++)if((address&1024)||b==bank){
                if(row[b]>=0){
                    check(cycle>=activated[b]+4,"SDRAM tRAS violation");
                    check(!last_write[b]||cycle>=last_write[b]+2,"SDRAM tWR violation");
                }
                row[b]=-1;closed[b]=cycle;
            }break;
        case 1:
            for(unsigned b=0;b<4;b++){
                check(row[b]<0,"SDRAM refresh with open bank");
                check(cycle>=closed[b]+2,"SDRAM refresh tRP violation");
            }
            if(last_refresh){
                auto gap=cycle-last_refresh;if(gap>max_refresh_gap)max_refresh_gap=gap;
                check(gap<=720,"SDRAM refresh exceeds retention interval");
            }
            last_refresh=cycle;++refreshes;blocked_until=cycle+6;break;
        case 0:
            check(bank==0&&(address&0x3ff)==0x21,"SDRAM mode must be CL2 sequential BL2");
            configured=true;blocked_until=cycle+2;break;
        default:throw std::runtime_error("unexpected SDRAM command");
        }
        return data;
    }
};
