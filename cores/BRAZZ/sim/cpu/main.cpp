// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vse3208.h"
#include "verilated.h"
#include "../obj_dir/cpu_reference/se3208_reference.hpp"
#include <algorithm>
#include <array>
#include <cctype>
#include <fstream>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>
#include <stdexcept>

static vluint64_t simulation_time=0;
double sc_time_stamp() { return double(simulation_time); }
static uint32_t random_state=0xc5e3208;
static uint32_t random32() { random_state^=random_state<<13; random_state^=random_state>>17; return random_state^=random_state<<5; }

struct BoardBus {
    ByteBus memory;
    bool pending=false, fail_access=false;
    bool consecutive_ce=false;
    unsigned delay=0;
    uint32_t reply=0;
    uint64_t clocks=0, transactions=0, split_candidates=0;
    std::vector<uint32_t> written;
    std::vector<uint8_t> events;
    // Coprocessor transport model: random request backpressure, delayed reply.
    bool cp_pending=false;
    unsigned cp_delay=0, cp_requests=0;
    uint32_t cp_reply=0, cp_last_data=0;
    unsigned cp_last_id=0, cp_last_register=0;
    bool cp_last_write=false;
    void tick(Vse3208& dut) {
        dut.clk=0; dut.ce=consecutive_ce ? 1 : clocks&1;
        dut.req_ready=!pending && ((random32()&3)!=0);
        dut.rsp_valid=pending && delay==0;
        dut.rsp_data=reply; dut.rsp_error=fail_access;
        dut.cp_req_ready=!cp_pending && ((random32()&3)!=0);
        dut.cp_rsp_valid=cp_pending && cp_delay==0;
        dut.cp_rsp_data=cp_reply; dut.cp_rsp_error=0;
        dut.eval(); ++simulation_time;
        const bool cp_accepted=dut.cp_req_valid && dut.cp_req_ready && !dut.reset;
        const bool cp_responded=dut.cp_rsp_valid && dut.cp_rsp_ready;
        if(cp_accepted) {
            ++cp_requests; cp_last_write=dut.cp_req_write; cp_last_id=dut.cp_req_id;
            cp_last_register=dut.cp_req_register; cp_last_data=dut.cp_req_data;
        }
        const bool accepted=dut.req_valid && dut.req_ready;
        const bool responded=dut.rsp_valid;
        const uint32_t address=dut.req_address, data=dut.req_data;
        const uint8_t strobe=dut.req_strobe;
        const bool write=dut.req_write;
        if(accepted && ((address&3) || !strobe)) throw std::runtime_error("invalid aligned board request");
        dut.clk=1; dut.eval(); ++simulation_time; ++clocks;
        if(dut.reset || dut.state_load) { pending=false; cp_pending=false; return; }
        if(cp_responded) cp_pending=false;
        else if(cp_pending && cp_delay) --cp_delay;
        if(cp_accepted) { cp_reply=random32(); cp_delay=random32()%5; cp_pending=true; }
        if(pending && delay) --delay;
        if(responded) pending=false;
        if(accepted) {
            if(pending) throw std::runtime_error("multiple outstanding requests");
            ++transactions;
            if(write && !fail_access) for(unsigned lane=0;lane<4;++lane) if(strobe&(1<<lane)) {
                memory.write_byte(address+lane,uint8_t(data>>(lane*8)));
                written.push_back(address+lane);
            }
            reply=memory.read_dword(address);
            delay=1+(random32()%7); pending=true;
        }
        if(dut.machine_event) events.push_back(dut.machine_code);
    }
    void run_instruction(Vse3208& dut) {
        for(unsigned timeout=0;timeout<4000;++timeout) {
            tick(dut);
            if(dut.fault) throw std::runtime_error("CPU fault");
            if(dut.retire) {consecutive_ce=false;return;}
        }
        throw std::runtime_error("instruction timeout");
    }
};

static bool compare(const Vse3208& dut,se3208_device& reference,BoardBus& bus,const std::vector<uint8_t>& expected_events) {
    bool equal=dut.pc==reference.m_PC && dut.sr==reference.m_SR && dut.sp==reference.m_SP && dut.er==reference.m_ER;
    for(unsigned i=0;i<8;++i) equal &= dut.registers[i]==reference.m_R[i];
    for(uint32_t address:bus.written) equal &= bus.memory.read_byte(address)==reference.m_program.read_byte(address);
    equal &= bus.memory.writes==reference.m_program.writes;
    equal &= bus.events==expected_events;
    if(!equal) {
        std::fprintf(stderr,"PC %08x/%08x SR %08x/%08x SP %08x/%08x ER %08x/%08x (RTL/MAME)\n",dut.pc,reference.m_PC,dut.sr,reference.m_SR,dut.sp,reference.m_SP,dut.er,reference.m_ER);
        for(unsigned i=0;i<8;++i) if(dut.registers[i]!=reference.m_R[i]) std::fprintf(stderr,"R%u %08x/%08x\n",i,dut.registers[i],reference.m_R[i]);
        for(uint32_t address:bus.written) if(bus.memory.read_byte(address)!=reference.m_program.read_byte(address)) std::fprintf(stderr,"memory %08x %02x/%02x\n",address,bus.memory.read_byte(address),reference.m_program.read_byte(address));
        if(bus.events!=expected_events) std::fprintf(stderr,"machine events %zu/%zu\n",bus.events.size(),expected_events.size());
        if(bus.memory.writes!=reference.m_program.writes) std::fprintf(stderr,"write trace bytes %zu/%zu\n",bus.memory.writes.size(),reference.m_program.writes.size());
    }
    return equal;
}

static void load_state(Vse3208& dut,se3208_device& reference,BoardBus& bus) {
    for(unsigned i=0;i<8;++i) dut.state_registers[i]=reference.m_R[i];
    dut.state_pc=reference.m_PC; dut.state_sr=reference.m_SR;
    dut.state_sp=reference.m_SP; dut.state_er=reference.m_ER;
    const bool requested_nmi=dut.nmi;
    dut.nmi=0; dut.state_load=1; bus.tick(dut); dut.state_load=0;
    dut.nmi=requested_nmi;
    bus.events.clear(); bus.written.clear();
}

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    Vse3208 dut;
    auto reference=std::make_unique<se3208_device>();
    std::vector<uint8_t> expected_events;
    reference->m_machinex_cb=[&](uint8_t code){expected_events.push_back(code);};
    uint8_t irq_vector_value=7;
    reference->m_iackx_cb=[&](){return irq_vector_value;};
    BoardBus bus;
    dut.reset=1; dut.state_load=0; dut.irq=0; dut.nmi=0; dut.irq_vector=7;
    bus.tick(dut); bus.tick(dut); dut.reset=0;
    unsigned tests=0, encodings=0, interrupts=0, excluded=0;
    for(unsigned opcode=0;opcode<65536;++opcode) {
        const std::string name=reference->operation_name(uint16_t(opcode));
        const bool bad_index=(name=="EXTB" || name=="EXTS" || name=="JR" || name=="CALLR") && (opcode&8);
        if(name=="INVALIDOP" || name=="MVFC" || name=="MVTC" || bad_index) {++excluded; continue;}
        ++encodings;
        const bool branch=name[0]=='J';
        const unsigned trials=branch ? 32 : (name=="MULS" ? 4 : 2);
        for(unsigned trial=0;trial<trials;++trial) {
            // Preserve normal CE-every-two cases, then exercise the new MULS
            // preparation interlock with consecutive enables and random operands.
            bus.consecutive_ce=name=="MULS" && trial>=2;
            reference->m_program=ByteBus{};
            for(unsigned i=0;i<8;++i) reference->m_R[i]=random32();
            reference->m_PC=0x100;
            reference->m_SP=0x1000+(opcode&3);
            reference->m_ER=random32();
            reference->m_SR=random32() & ~0x20f0u;
            reference->m_SR |= (trial&15)<<4;
            if(trial&16) reference->m_SR |= 0x800;
            // Exercise IRQ/NMI entry across every instruction class, including
            // software status changes, POP SR and disabled SWI.
            dut.irq=(opcode%101)==0 && trial==0;
            dut.nmi=(opcode%103)==0 && trial==0;
            if(dut.irq) reference->m_SR |= 0x2000;
            reference->m_IRQ=dut.irq; reference->m_NMI=dut.nmi;
            if(dut.irq || dut.nmi) ++interrupts;
            uint32_t offset=opcode&31, address=0;
            if((opcode>>14)==0) {
                unsigned kind=(opcode>>11)&7;
                if(kind==1 || kind==5 || kind==7) offset<<=1;
                if(kind==2 || kind==6) offset<<=2;
                if(reference->m_SR&0x800) offset=(reference->m_ER<<4)|(offset&15);
                const unsigned index=(opcode>>5)&7;
                address=(index ? reference->m_R[index] : 0)+offset;
            } else if(name=="LDSP" || name=="STSP") {
                offset=(opcode&255)<<2;
                if(reference->m_SR&0x800) offset=(reference->m_ER<<4)|(offset&15);
                address=reference->m_SP+offset;
            } else if(name=="LDBSP" || name=="LDBUSP" || name=="STBSP" || name=="LDSSP" || name=="LDSUSP" || name=="STSSP") {
                offset=opcode&15;
                if(name=="LDSSP" || name=="LDSUSP" || name=="STSSP") offset<<=1;
                if(reference->m_SR&0x800) offset=(reference->m_ER<<4)|(offset&15);
                address=reference->m_SP+offset;
            }
            reference->m_program.write_dword(address,random32());
            for(int delta=-48;delta<48;delta+=4) reference->m_program.write_dword(reference->m_SP+delta,random32());
            for(unsigned vector=1;vector<32;++vector) reference->m_program.write_dword(vector*4,random32());
            reference->m_program.write_word(0x100,uint16_t(opcode));
            reference->m_program.trace_writes=true;
            bus.memory=reference->m_program;
            load_state(dut,*reference,bus);
            expected_events.clear(); reference->step();
            try { bus.run_instruction(dut); }
            catch(const std::exception& error) {
                std::fprintf(stderr,"FAIL %s opcode=%04x trial=%u: %s faultPC=%08x faultOpcode=%04x\n",name.c_str(),opcode,trial,error.what(),dut.fault_pc,dut.fault_opcode); return 1;
            }
            if(dut.retire_pc!=0x100 || dut.retire_opcode!=opcode || !compare(dut,*reference,bus,expected_events)) {
                std::fprintf(stderr,"FAIL %s opcode=%04x trial=%u\n",name.c_str(),opcode,trial); return 1;
            }
            ++tests;
        }
    }


    // ---- Passes 1 and 2: exception/fetch/address stress and the encodings that
    // pass 0 excludes. All of them compare against the same MAME oracle.
    //
    // Vendor (primary ADChips tool) classification of FC00..FFFF, read from the
    // probe output independently of the RTL decoder.
    std::array<std::string,1024> vendor;
    {
        std::ifstream primary("sim/obj_dir/isa_research/vendor_bin/control_family.csv");
        std::string line; unsigned count=0;
        if(!primary || !std::getline(primary,line) || line!="opcode,mnemonic,operands") {std::fprintf(stderr,"FAIL missing primary vendor oracle; run scripts/se3208_vendor_probe.py\n");return 2;}
        while(std::getline(primary,line)) {
            const auto comma=line.find(','), end=line.find(',',comma+1);
            if(comma==std::string::npos || end==std::string::npos || count>=vendor.size() || std::stoul(line.substr(0,comma),nullptr,16)!=0xfc00u+count) return 2;
            auto name=line.substr(comma+1,end-comma-1);
            std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return std::toupper(c);});
            vendor[count++]=name;
        }
        if(count!=vendor.size()) return 2;
    }
    const std::array<uint32_t,16> edges={0,1,2,3,0xffffffff,0xfffffffe,0xfffffffd,0xfffffffc,0x80000000,0x7fffffff,0xfffffff0,0x100,0xff,0xffff,0x1fe,0x3ff};
    const std::array<uint32_t,8> pcs={0x100,0x101,0x102,0x103,0x3fe,0xfffffffe,0xffffffff,0x1fd};
    // pass 1: every defined encoding with random ENI/AUT/IRQ/NMI/vector, odd and
    // wrapping PCs/SPs/bases. pass 2: excluded encodings.
    unsigned stress_tests=0, stress_interrupts=0, nop_encodings=0, cp_encodings=0, fault_encodings=0, swi_taken=0;
    unsigned pass2_cp_reads=0, pass2_cp_writes=0;
    for(unsigned pass=1;pass<=2;++pass)
    for(unsigned opcode=0;opcode<65536;++opcode) {
        const std::string name=reference->operation_name(uint16_t(opcode));
        const bool bad_index=(name=="EXTB" || name=="EXTS" || name=="JR" || name=="CALLR") && (opcode&8);
        const bool mame_excluded=name=="INVALIDOP" || name=="MVFC" || name=="MVTC" || bad_index;
        if((pass==1)==mame_excluded) continue;
        const std::string vendor_name=opcode>=0xfc00 ? vendor[opcode-0xfc00] : "";
        const bool vendor_cp=vendor_name=="MVTC" || vendor_name=="MVFC";
        const unsigned trials=pass==1 ? (name=="SWI" ? 16 : 2) : 3;
        for(unsigned trial=0;trial<trials;++trial) {
            bus.consecutive_ce=pass==1 && name=="MULS" && (random32()&1);
            reference->m_program=ByteBus{};
            for(unsigned i=0;i<8;++i) reference->m_R[i]=(random32()&3)==0 ? edges[random32()&15] : random32();
            const uint32_t pc=pcs[(opcode+trial)%pcs.size()];
            reference->m_PC=pc;
            reference->m_SP=((random32()&3)==0 ? edges[random32()&15] : 0x1000+(random32()&0x3f)) + (random32()&3);
            reference->m_ER=random32();
            reference->m_SR=random32();
            if(random32()&1) reference->m_SR|=0x800; else reference->m_SR&=~0x800u;
            if(random32()&3) reference->m_SR|=0x2000; else reference->m_SR&=~0x2000u;
            if(name=="SWI") reference->m_SR|=0x2000;
            if(name=="SWI" && trial>=8) reference->m_SR&=~0x2000u;
            const uint32_t sr_before=reference->m_SR;
            dut.irq=(random32()%3)==0;
            dut.nmi=(random32()%5)==0;
            irq_vector_value=uint8_t(random32()); dut.irq_vector=irq_vector_value;
            reference->m_IRQ=dut.irq; reference->m_NMI=dut.nmi;
            if(dut.irq || dut.nmi) ++stress_interrupts;
            uint32_t offset=opcode&31, address=0;
            if((opcode>>14)==0) {
                unsigned kind=(opcode>>11)&7;
                if(kind==1 || kind==5 || kind==7) offset<<=1;
                if(kind==2 || kind==6) offset<<=2;
                if(reference->m_SR&0x800) offset=(reference->m_ER<<4)|(offset&15);
                const unsigned index=(opcode>>5)&7;
                address=(index ? reference->m_R[index] : 0)+offset;
            } else if(name=="LDSP" || name=="STSP") {
                offset=(opcode&255)<<2;
                if(reference->m_SR&0x800) offset=(reference->m_ER<<4)|(offset&15);
                address=reference->m_SP+offset;
            } else if(name=="LDBSP" || name=="LDBUSP" || name=="STBSP" || name=="LDSSP" || name=="LDSUSP" || name=="STSSP") {
                offset=opcode&15;
                if(name=="LDSSP" || name=="LDSUSP" || name=="STSSP") offset<<=1;
                if(reference->m_SR&0x800) offset=(reference->m_ER<<4)|(offset&15);
                address=reference->m_SP+offset;
            }
            for(int delta=-8;delta<=8;delta+=4) reference->m_program.write_dword(address+delta,random32());
            for(int delta=-48;delta<48;delta+=4) reference->m_program.write_dword(reference->m_SP+delta,random32());
            for(unsigned vector=0;vector<256;++vector) reference->m_program.write_dword(vector*4,random32());
            reference->m_program.write_word(pc,uint16_t(opcode));
            reference->m_program.trace_writes=true;
            bus.memory=reference->m_program;
            const uint32_t r0_before=reference->m_R[0];
            load_state(dut,*reference,bus);
            bus.cp_requests=0; expected_events.clear();
            auto describe=[&](const char* why){std::fprintf(stderr,"FAIL pass %u %s opcode=%04x trial=%u pc=%08x sr=%08x irq=%d nmi=%d: %s\n",pass,name.c_str(),opcode,trial,pc,sr_before,int(dut.irq),int(dut.nmi),why);};
            if(bad_index) {
                // Out-of-array register index: undefined in MAME; the RTL must stop
                // visibly at this instruction and never retire or touch memory/CP.
                dut.irq=0; dut.nmi=0; reference->m_IRQ=0; reference->m_NMI=0;
                bool faulted=false;
                for(unsigned t=0;t<4000 && !faulted && !dut.retire;++t) {bus.tick(dut); faulted=dut.fault;}
                if(!faulted || dut.retire || dut.fault_pc!=pc || dut.fault_opcode!=opcode || !bus.written.empty() || bus.cp_requests) {describe("expected explicit fault");return 1;}
                for(unsigned t=0;t<16;++t) bus.tick(dut);
                if(dut.retire || !bus.written.empty() || bus.cp_requests) {describe("activity after fault");return 1;}
                if(trial==0) ++fault_encodings;
                ++stress_tests; continue;
            }
            reference->step();
            try { bus.run_instruction(dut); }
            catch(const std::exception& error) { describe(error.what()); std::fprintf(stderr,"faultPC=%08x faultOpcode=%04x\n",dut.fault_pc,dut.fault_opcode); return 1; }
            // MAME's MVTC/MVFC/INVALIDOP are empty handlers. The RTL differs only
            // where the primary vendor encoding names a coprocessor transfer: MVTC
            // issues R0, MVFC returns the reply into R0 (nothing else changes).
            if(pass==2) {
                if(vendor_cp) {
                    const bool read=vendor_name=="MVFC";
                    if(bus.cp_requests!=1 || bus.cp_last_write==read || bus.cp_last_id!=((opcode>>8)&3) || bus.cp_last_register!=(opcode&7) || (!read && bus.cp_last_data!=r0_before)) {describe("wrong coprocessor request");return 1;}
                    if(read) {reference->m_R[0]=bus.cp_reply; ++pass2_cp_reads;} else ++pass2_cp_writes;
                    if(trial==0) ++cp_encodings;
                } else {
                    if(bus.cp_requests) {describe("unexpected coprocessor request");return 1;}
                    if(trial==0) ++nop_encodings;
                }
            } else if(bus.cp_requests) {describe("unexpected coprocessor request");return 1;}
            if(name=="SWI" && (sr_before&0x2000)) ++swi_taken;
            if(dut.retire_pc!=pc || dut.retire_opcode!=opcode || !compare(dut,*reference,bus,expected_events)) {describe("state mismatch");return 1;}
            ++stress_tests;
        }
    }
    dut.irq=0; dut.nmi=0; dut.irq_vector=7; irq_vector_value=7; bus.consecutive_ce=false;

    // Genuine reset-vector fetch and a short multi-instruction program. No state
    // loading is used here; this is CPU bring-up proof, not a game boot claim.
    bus.memory=ByteBus{}; bus.events.clear(); bus.written.clear();
    bus.memory.write_dword(0,0x100);
    const std::array<uint16_t,6> program={0xe805,0xe907,0xc202,0x3214,0x1314,0xdeff};
    for(unsigned i=0;i<program.size();++i) bus.memory.write_word(0x100+i*2,program[i]);
    reference->m_program=bus.memory; reference->device_reset();
    reference->m_program.trace_writes=true; bus.memory.trace_writes=true;
    dut.irq=0; dut.nmi=0; dut.reset=1; bus.tick(dut); bus.tick(dut); dut.reset=0;
    for(unsigned i=0;i<10;++i) {
        bus.events.clear(); bus.written.clear(); bus.memory.writes.clear(); reference->m_program.writes.clear(); expected_events.clear(); reference->step();
        try {bus.run_instruction(dut);} catch(const std::exception& error) {std::fprintf(stderr,"FAIL reset program: %s\n",error.what());return 1;}
        if(!compare(dut,*reference,bus,expected_events)) {std::fprintf(stderr,"FAIL reset program instruction %u\n",i);return 1;}
    }
    if(dut.registers[2]!=12 || dut.registers[3]!=12 || dut.pc!=0x10a) {std::fprintf(stderr,"FAIL reset program result\n");return 1;}
    // Memory errors must stop visibly, with no fabricated instruction retirement.
    reference->m_PC=0x100; load_state(dut,*reference,bus); bus.fail_access=true;
    for(unsigned i=0;i<100 && !dut.fault;++i) bus.tick(dut);
    if(!dut.fault || dut.retire) {std::fprintf(stderr,"FAIL missing fetch fault\n");return 1;}
    const auto fault_transactions=bus.transactions;
    for(unsigned i=0;i<32;++i) bus.tick(dut);
    if(bus.transactions!=fault_transactions || dut.retire) {std::fprintf(stderr,"FAIL activity after fault\n");return 1;}
    std::printf("PASS SE3208 CPU: %u differential instructions across %u encodings, %u IRQ/NMI cases; reset-vector program, variable bus latency/backpressure, unaligned accesses and explicit bus fault. %u MAME-unresolved encodings excluded from pass 0 and covered by pass 2 (%u MAME-NOP-equivalent, %u vendor MVTC/MVFC transfers, %u explicit faults). Stress pass: %u instructions with random ENI/AUT/IRQ/NMI/vector, odd/wrapping PC/SP/bases (%u interrupt cases, %u enabled SWI). %llu clocks / %llu bus requests / %u CP transfers\n",tests,encodings,interrupts,excluded,nop_encodings,cp_encodings,fault_encodings,stress_tests,stress_interrupts,swi_taken,(unsigned long long)bus.clocks,(unsigned long long)bus.transactions,pass2_cp_reads+pass2_cp_writes);
    return 0;
}
