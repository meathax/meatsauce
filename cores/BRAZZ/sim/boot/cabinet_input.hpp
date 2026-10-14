// SPDX-License-Identifier: GPL-3.0-or-later
// Host simulation driver: change physical cabinet pins only, never game state.
#pragma once
#include <charconv>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
struct CabinetInput {
    const std::string command_path;
    const uint64_t poll_period;
    std::ofstream history;
    uint64_t next_poll=0,last_sequence=0,commands=0,releases=0,invalid_polls=0;
    uint64_t release_frame=0;
    bool release_pending=false;
    CabinetInput(const std::string& command,const std::string& log,uint64_t period=500000):
        command_path(command),poll_period(period),history(log,std::ios::trunc){
        if(!period || !history)throw std::runtime_error("cabinet input log/period");
        history << "clock,frame,sequence,event,p1_p2_n,p3_p4_n,system_n,dips_n\n";
        history.flush();
    }
    static bool number(const std::string& text,unsigned base,uint64_t& value){
        auto r=std::from_chars(text.data(),text.data()+text.size(),value,int(base));
        return r.ec==std::errc() && r.ptr==text.data()+text.size();
    }
    template<class Dut> void record(uint64_t clock,uint64_t frame,const char* event,const Dut& d){
        history << std::dec << clock << ',' << frame << ',' << last_sequence << ',' << event
                << ',' << std::hex << std::setfill('0') << std::setw(8) << d.p1_p2_n
                << ',' << std::setw(8) << d.p3_p4_n << ',' << std::setw(2) << unsigned(d.system_n)
                << ',' << std::setw(2) << unsigned(d.dips_n) << std::dec << '\n';
        history.flush();
        if(!history)throw std::runtime_error("cabinet input history write");
    }
    template<class Dut> void tick(uint64_t clock,uint64_t frame,Dut& d){
        if(release_pending && frame>=release_frame){
            d.p1_p2_n=0xffffffff;d.p3_p4_n=0xffffffff;d.system_n=0xff;
            release_pending=false;++releases;record(clock,frame,"release",d);
        }
        if(clock<next_poll)return;
        next_poll=clock>std::numeric_limits<uint64_t>::max()-poll_period ?
                  std::numeric_limits<uint64_t>::max() : clock+poll_period;
        std::ifstream file(command_path);
        if(!file)return;
        char line[256];file.getline(line,sizeof(line));
        // An unfinished write can already contain six parseable tokens.
        // Require its terminating newline before changing any physical pins.
        if(file.fail() || file.eof()){++invalid_polls;return;}
        std::string row(line);auto comment=row.find('#');if(comment!=std::string::npos)row.resize(comment);
        std::istringstream words(row);std::string text[6],extra;
        for(auto& word:text)if(!(words>>word)){++invalid_polls;return;}
        if(words>>extra){++invalid_polls;return;}
        uint64_t values[6]{};
        for(unsigned i=0;i<6;++i)if(!number(text[i],i<2?10:16,values[i])){++invalid_polls;return;}
        if(values[0]<=last_sequence)return;
        if(values[2]>0xffffffff || values[3]>0xffffffff || values[4]>0xff || values[5]>0xff ||
           values[1]>std::numeric_limits<uint64_t>::max()-frame){++invalid_polls;return;}
        last_sequence=values[0];++commands;
        d.p1_p2_n=uint32_t(values[2]);d.p3_p4_n=uint32_t(values[3]);
        d.system_n=uint8_t(values[4]);d.dips_n=uint8_t(values[5]);
        release_pending=values[1]!=0;release_frame=frame+values[1];
        record(clock,frame,"apply",d);
    }
};
