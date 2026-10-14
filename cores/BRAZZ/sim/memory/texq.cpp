// cs_texq bench: ordering of texture writes and display-list front updates against a renderer model,
// read-after-write blocking, forwarding of just-written words, pass-through of everything else,
// full-queue backpressure.
// Board side behaves like cs_bus_arbiter: a request is presented until accepted (b_ready), then dropped
// until its response (b_rsp_valid).
#include "Vcs_texq.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <stdexcept>
#include <string>
double sc_time_stamp(){return 0;}
static unsigned checks=0;
static void ck(bool b,const std::string&s){++checks;if(!b)throw std::runtime_error(s);}
struct Bench{
    Vcs_texq d;uint64_t clk=0;
    bool busy=false;int left=0;bool rsp=false;
    Bench(){d.b_realtime=0;d.rt_waiting=0;}
    std::deque<std::pair<uint32_t,uint32_t>> applied; // texture drain writes in order of reaching the fabric
    std::deque<unsigned> fronts;
    bool accepted=false,responded=false;uint32_t rsp_data=0;
    void tick(){
        d.clk=0;d.eval();
        d.f_ready=!busy;d.f_rsp_valid=rsp;d.f_rsp_data=0x1234;d.f_rsp_error=0;d.eval();
        const bool fab=d.f_valid&&d.f_ready;
        accepted=d.b_valid&&d.b_ready;responded=d.b_rsp_valid;rsp_data=d.b_rsp_data;
        const bool dr=d.f_drain,fw=d.f_write;const uint32_t fo=d.f_offset,fd=d.f_data;const unsigned ft=d.f_target;
        if(d.front_set)fronts.push_back(d.front_set_val);
        d.clk=1;d.eval();++clk;
        rsp=false;if(busy&&--left==0){busy=false;rsp=true;}
        if(fab){busy=true;left=6;if(dr&&fw&&ft==2)applied.emplace_back(fo,fd);}
    }
    void run(unsigned n){for(unsigned i=0;i<n;i++)tick();}
    // present a request until accepted; returns true if accepted within max clocks (request then dropped)
    bool present(unsigned target,uint32_t offset,bool write,uint32_t data=0,unsigned strobe=15,unsigned max=200){
        d.b_valid=1;d.b_target=target;d.b_offset=offset;d.b_write=write;d.b_data=data;d.b_strobe=strobe;
        for(unsigned i=0;i<max;i++){tick();if(accepted){d.b_valid=0;return true;}}
        d.b_valid=0;tick();return false;
    }
    uint32_t wait_response(unsigned max=2000){for(unsigned i=0;i<=max;i++){if(responded)return rsp_data;tick();}throw std::runtime_error("response timeout");}
    uint32_t access(unsigned target,uint32_t offset,bool write,uint32_t data=0,unsigned strobe=15,unsigned max=200000){
        ck(present(target,offset,write,data,strobe,max),"request not accepted");
        // the response may already be visible on the accepting clock's successor
        uint32_t r=wait_response();tick();return r;
    }
};
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);
    try{Bench b;
        b.d.reset=1;b.d.drain_ok=0;b.d.front_wr=0;b.d.b_valid=0;b.tick();b.tick();b.d.reset=0;b.run(8);
        ck(b.d.empty,"empty after reset");
        // 1. writes are acknowledged at once and held while the renderer has not caught up (drain_ok=0)
        for(unsigned i=0;i<5;i++)b.access(2,0x1000+4*i,true,0xa0+i,15,200);
        b.run(100);ck(b.applied.empty(),"texture writes applied before drain_ok");ck(!b.d.empty,"queue holds the writes");
        // 2. front update queued behind the writes does not pass to the renderer
        b.d.front_wr=1;b.d.front_wr_val=7;b.tick();b.d.front_wr=0;b.run(50);ck(b.fronts.empty(),"front passed ahead of queued writes");
        // 3. a read of a bucket with a queued write (word not in the forwarding shadow) is held; a read of an
        // untouched bucket passes
        ck(!b.present(2,0x1018,false,0,15,60),"read-after-write was not held");
        ck(b.present(2,0x4000,false,0,15,60),"read of an untouched bucket was held");b.wait_response();b.run(3);
        // 3b. a real-time requester (sound) is never held, even for a bucket with a queued write
        b.d.b_realtime=1;ck(b.present(2,0x1008,false,0,15,60),"real-time read was held");b.wait_response();b.run(3);b.d.b_realtime=0;
        // 3c. drains keep off the fabric while a real-time client is waiting, and for a while after
        b.d.drain_ok=1;b.d.rt_waiting=1;b.run(200);ck(b.applied.empty(),"drain issued while a real-time client waits");b.d.rt_waiting=0;b.d.drain_ok=0;
        // 4. release: writes drain in order, then the front is handed over
        b.d.drain_ok=1;b.run(400);
        ck(b.applied.size()==5,"drained write count");
        for(unsigned i=0;i<5;i++)ck(b.applied[i].first==0x1000+4*i&&b.applied[i].second==0xa0+i,"drain order/data");
        ck(b.fronts.size()==1&&b.fronts[0]==7,"front value after the writes");ck(b.d.empty,"queue empty after drain");
        // 5. the held read completes now
        ck(b.present(2,0x1008,false,0,15,60),"read after drain still held");b.wait_response();b.run(3);
        // 6. non-texture requests pass through unchanged, responses forwarded
        ck(b.access(1,0x20,true,0x55,15)==0x1234,"pass-through write response");
        ck(b.access(1,0x20,false)==0x1234,"pass-through read response");
        // 7. renderer busy again: a new write waits; byte strobes survive the queue
        b.applied.clear();b.d.drain_ok=0;b.access(2,0x2000,true,0xdeadbeef,0x5,200);b.run(60);ck(b.applied.empty(),"write applied while renderer busy");
        b.d.drain_ok=1;b.run(100);ck(b.applied.size()==1&&b.applied[0].first==0x2000&&b.applied[0].second==0xdeadbeef,"offset/data after drain");
        // 8. backpressure: with the renderer busy the queue accepts about DEPTH-16 words, then the CPU is held
        b.d.drain_ok=0;unsigned accepted=0;
        for(unsigned i=0;i<5000;i++){
            if(!b.present(2,0x10000+4*(i&0xfff),true,i,15,12))break;
            b.wait_response();++accepted;b.tick();}
        ck(accepted>=4000&&accepted<4096,"queue depth "+std::to_string(accepted));
        b.d.drain_ok=1;b.run(60000);ck(b.d.empty,"large drain");
        // 9. a pass-through read is not starved by a long drain: it completes while drain writes are pending
        b.d.drain_ok=0;for(unsigned i=0;i<40;i++){b.present(2,0x20000+4*i,true,i,15,12);b.wait_response();b.tick();}
        b.d.drain_ok=1;ck(b.access(1,0x40,false,0,15,400)==0x1234,"pass-through during drain");b.run(2000);ck(b.d.empty,"drain completes");
        // 10. forwarding (shadow swept long ago): reads of just-written words are answered from the shadow with
        // the newest lanes while the writes are still queued; partial or replaced entries fall back to the hold
        b.applied.clear();b.d.drain_ok=0;
        b.access(2,0x5000,true,0x11111111,15);b.access(2,0x5004,true,0x22222222,15);b.run(4);
        ck(b.present(2,0x5000,false,0,15,20),"forwarded read was held");ck(b.wait_response(4)==0x11111111,"forwarded data");b.run(3);
        b.access(2,0x5000,true,0x0000c100,0x2);b.run(4);
        ck(b.present(2,0x5000,false,0,15,20),"merged read was held");ck(b.wait_response(4)==0x1111c111,"merged lanes");b.run(3);
        b.access(2,0x5040,true,0x5566,0x3);b.run(4);
        ck(!b.present(2,0x5040,false,0,15,60),"read of lanes not in the shadow was forwarded");
        ck(b.present(2,0x5040,false,0,0x3,20),"read of shadowed lanes was held");ck((b.wait_response(4)&0xffff)==0x5566,"partial forward");b.run(3);
        b.access(2,0x7000,true,0x77,15);b.run(4); // same shadow entry and bucket as 0x5000: replaces it
        ck(!b.present(2,0x5000,false,0,15,60),"read of a replaced shadow entry was forwarded");
        ck(b.present(2,0x7000,false,0,15,20),"read of the replacing word was held");ck(b.wait_response(4)==0x77,"replacing data");b.run(3);
        ck(b.applied.empty(),"forwarding applied a write");
        b.d.drain_ok=1;b.run(400);ck(b.d.empty,"drain after forwarding");
        ck(b.applied.size()==5&&b.applied[2].first==0x5000&&b.applied[2].second==0x0000c100&&b.applied[4].first==0x7000,"drain order after forwarding");
        ck(b.access(2,0x5000,false)==0x1234,"read after drain goes to the fabric");
        std::printf("PASS texq: %u checks; in-order drain behind the renderer, front ordering, read-after-write hold, forwarding shadow, pass-through, depth %u\n",checks,accepted);return 0;
    }catch(const std::exception&e){std::fprintf(stderr,"FAIL texq: %s\n",e.what());return 1;}
}
