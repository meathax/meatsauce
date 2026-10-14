// SPDX-License-Identifier: GPL-3.0-or-later
#include "Vse3208_decode.h"
#include "verilated.h"
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>
#include <array>
#include <algorithm>
#include <cctype>

double sc_time_stamp() { return 0; }
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const std::vector<std::string> names = {
        "ADC","ADCI","ADD","ADDI","AND","ANDI","ASL","ASR","CALL","CALLR",
        "CLR","CMP","CMPI","EXTB","EXTS","HALT","INVALIDOP","JC","JGE","JGT",
        "JHI","JLE","JLS","JLT","JM","JMP","JNC","JNV","JNZ","JP","JR","JV","JZ",
        "LD","LDB","LDBSP","LDBU","LDBUSP","LDI","LDS","LDSP","LDSSP","LDSU",
        "LDSUSP","LEAFROMSP","LEASPTOSP","LEATOSP","LERI","LSR","MOV","MULS",
        "MVFC","MVTC","NEG","OR","ORI","POP","PUSH","SBC","SBCI","SET","ST",
        "STB","STBSP","STS","STSP","STSSP","SUB","SUBI","SWI","TST","TSTI","XOR","XORI",
        "CCMD","GETC","EXC","LDC","STC"
    };
    std::array<std::string,1024> vendor;
    std::ifstream primary("sim/obj_dir/isa_research/vendor_bin/control_family.csv");
    if(!primary) { std::fprintf(stderr,"FAIL missing primary vendor oracle; run scripts/se3208_vendor_probe.py\n");return 2; }
    std::string line; unsigned vendor_count=0;
    if(!std::getline(primary,line) || line!="opcode,mnemonic,operands") return 2;
    while(std::getline(primary,line)) {
        const auto comma=line.find(',');
        const auto end=line.find(',',comma+1);
        if(comma==std::string::npos || end==std::string::npos) return 2;
        const unsigned opcode=std::stoul(line.substr(0,comma),nullptr,16);
        if(opcode!=0xfc00+vendor_count || vendor_count>=vendor.size()) return 2;
        auto name=line.substr(comma+1,end-comma-1);
        std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return std::toupper(c);});
        vendor[vendor_count++]=name=="UNKNOWN" ? "INVALIDOP" : name;
    }
    if(vendor_count!=1024) return 2;
    std::ifstream input("sim/obj_dir/cpu_reference/decode.csv");
    if (!input) { std::fprintf(stderr,"FAIL missing MAME decoder oracle; run scripts/cpu_reference.py\n"); return 2; }
    Vse3208_decode dut;
    unsigned count = 0, corrections=0;
    while (std::getline(input,line)) {
        const auto comma = line.find(',');
        if (comma == std::string::npos) { std::fprintf(stderr,"FAIL malformed oracle line\n"); return 2; }
        const unsigned opcode = std::stoul(line.substr(0,comma),nullptr,16);
        if (opcode != count) { std::fprintf(stderr,"FAIL incomplete oracle\n"); return 2; }
        dut.opcode = opcode; dut.eval();
        const std::string mame = line.substr(comma+1);
        const std::string expected = opcode>=0xfc00 ? vendor[opcode-0xfc00] : mame;
        corrections+=expected!=mame;
        if (dut.operation >= names.size() || names[dut.operation] != expected) {
            std::fprintf(stderr,"FAIL opcode %04x: RTL=%u expected=%s\n",opcode,dut.operation,expected.c_str());
            return 1;
        }
        ++count;
    }
    if (count != 65536) { std::fprintf(stderr,"FAIL oracle contains %u opcodes\n",count); return 2; }
    std::printf("PASS SE3208 decoder: 64512 MAME encodings + 1024 primary ADChips encodings; %u vendor corrections to MAME. Effects of coprocessor instructions remain unsupported.\n",corrections);
    return 0;
}
