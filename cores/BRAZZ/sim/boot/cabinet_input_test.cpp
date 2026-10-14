// SPDX-License-Identifier: GPL-3.0-or-later
#include "cabinet_input.hpp"
#include <filesystem>
#include <iostream>
struct Pins {uint32_t p1_p2_n=0xffffffff,p3_p4_n=0xffffffff;uint8_t system_n=0xff,dips_n=0xff;};
static unsigned checks=0;
static void check(bool value){++checks;if(!value)throw std::runtime_error("cabinet check "+std::to_string(checks));}
int main(){
    try{
        const std::string root="sim/obj_dir/cabinet_input_test";std::filesystem::create_directories(root);
        auto command=[&](const char* text){std::ofstream f(root+"/command.txt",std::ios::trunc);f<<text;};
        command("0 0 ffffffff ffffffff ff ff\n");
        CabinetInput input(root+"/command.txt",root+"/history.csv",1);Pins d;
        input.tick(0,10,d);check(!input.commands && d.system_n==0xff);
        command("1 2 ffffffff ffffffff ef ff\n");input.tick(1,10,d);
        check(input.commands==1 && input.release_frame==12 && d.system_n==0xef);
        input.tick(2,11,d);check(input.commands==1 && d.system_n==0xef);
        input.tick(3,12,d);check(input.releases==1 && d.system_n==0xff);
        command("2 0 ffbffffe ffffffff ff fd\n");input.tick(4,13,d);input.tick(5,999,d);
        check(input.commands==2 && !input.release_pending && d.p1_p2_n==0xffbffffe && d.dips_n==0xfd);
        command("3 1 ffffffff ffffffff fe fd # start P1\n");input.tick(6,999,d);
        check(d.system_n==0xfe && input.commands==3);
        input.tick(7,1000,d);check(d.system_n==0xff && d.dips_n==0xfd && input.releases==2);
        command("2 0 00000000 00000000 00 00\n");input.tick(8,1000,d);check(input.commands==3 && d.system_n==0xff);
        const char* invalid[]={"-4 1 ffffffff ffffffff df fd\n","4 1 ffffffff ffffffff 1ff fd\n",
                               "4 1 fffffffff ffffffff df fd\n","4 1 ffffffff\n",
                               "4 1 ffffffff ffffffff df fd extra\n","4 1 ffffffff ffffffff df f"};
        uint64_t clock=9;
        for(auto text:invalid){command(text);input.tick(clock++,1000,d);check(input.commands==3 && input.last_sequence==3 && d.system_n==0xff);}
        check(input.invalid_polls==6);
        command("4 2 ffffffff ffffffff df fd\n");input.tick(clock++,1000,d);
        check(input.commands==4 && d.system_n==0xdf);
        input.tick(clock++,1002,d);check(input.releases==3 && d.system_n==0xff && d.dips_n==0xfd);
        std::ifstream log(root+"/history.csv");std::string row;unsigned rows=0;while(std::getline(log,row))++rows;
        check(rows==8); // header + four applied commands + three automatic releases
        // File polling is bounded, while deadline releases still occur on the actual frame boundary.
        command("1 1 fffffffe fffffffd ff ff\n");CabinetInput slow(root+"/command.txt",root+"/slow.csv",10);Pins pair;
        slow.tick(0,0,pair);check(pair.p1_p2_n==0xfffffffe && pair.p3_p4_n==0xfffffffd);
        command("2 0 ffffffff ffffffff 7f ff\n");slow.tick(1,1,pair);
        check(slow.releases==1 && slow.commands==1 && pair.system_n==0xff);
        slow.tick(10,2,pair);check(slow.commands==2 && pair.system_n==0x7f);
        std::cout<<"PASS live cabinet driver: "<<checks<<" checks; coin/start/P1/P2-width pins, frame release, persistent DIPs, stale/invalid commands, bounded polls/history\n";
        return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
