// SPDX-License-Identifier: GPL-3.0-or-later
// Arbiter lock preemption: a background grant that is never accepted (endpoint holds it) is handed to a waiting
// priority client after PREEMPT_AGE clocks; the held request is granted again afterwards. A held request is
// never preempted once it has been accepted (response pending), and without a priority client waiting it stays.
#include "Vcs_bus_arbiter.h"
#include "verilated.h"
#include <iostream>
#include <stdexcept>
double sc_time_stamp(){return 0;}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    try{
        Vcs_bus_arbiter d;
        auto clock=[&](){d.clk=1;d.eval();d.clk=0;d.eval();};
        auto ck=[&](bool b,const char*m){if(!b)throw std::runtime_error(m);};
        d.reset=1;d.client_valid=0;d.req_ready=0;d.rsp_valid=0;d.client_strobe=0xfffff;clock();d.reset=0;clock();
        // client 0 (CPU) requests; the endpoint refuses (req_ready=0): the lock ages
        d.client_valid=1;d.eval();
        for(int i=0;i<4;i++){clock();d.eval();}
        ck(d.req_valid&&d.req_client==0,"background request granted and held");
        for(int i=0;i<60;i++){clock();d.eval();ck(d.req_client==0&&d.req_valid,"lock must hold with no priority client waiting");}
        // sound (client 3) arrives: after the age limit the lock moves to it
        d.client_valid=1|(1<<3);d.eval();
        int moved=-1;
        for(int i=0;i<100&&moved<0;i++){clock();d.eval();if(d.req_valid&&d.req_client==3)moved=i;}
        ck(moved>=0,"priority client never preempted the stalled lock");
        // the endpoint accepts the sound request; response follows
        d.req_ready=1;d.eval();ck(d.req_valid&&d.req_client==3&&(d.client_ready&8),"sound request ready");clock();
        d.req_ready=0;d.client_valid=1;d.eval(); // sound done after its response
        d.rsp_valid=1;d.eval();ck(d.client_rsp_valid&8,"response to sound");clock();d.rsp_valid=0;d.eval();
        // the held CPU request is granted again and accepted normally
        for(int i=0;i<10&&!(d.req_valid&&d.req_client==0);i++){clock();d.eval();}
        ck(d.req_valid&&d.req_client==0,"held request granted again");
        d.req_ready=1;d.eval();ck(d.client_ready&1,"held request accepted after release");clock();
        // an accepted background request is never preempted: response pending, sound waits
        d.req_ready=0;d.client_valid=1|(1<<3);d.eval();
        for(int i=0;i<200;i++){clock();d.eval();ck(!d.req_valid,"no new grant while a response is pending");}
        d.rsp_valid=1;d.eval();ck(d.client_rsp_valid&1,"response to CPU");clock();d.rsp_valid=0;d.eval();
        std::cout<<"PASS arbiter preemption: stalled background lock handed to the sound client, held request re-granted, accepted request untouched\n";return 0;
    }catch(const std::exception&e){std::cerr<<"FAIL arbiter preemption: "<<e.what()<<"\n";return 1;}
}
