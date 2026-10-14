"""Extract an independent standalone SE3208 interpreter from pinned BSD MAME.

Instruction/helper bodies are copied unchanged. Only emulator integration is
replaced by a byte-addressed bus and no-op debugger/log adapters. This is a
test oracle, never the CPU used by the FPGA board simulation.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/reference/mame/src/devices/cpu/se3208/se3208.cpp"
OUT = ROOT / "sim/obj_dir/cpu_reference"
CXX = Path(r"D:\vibes\fpga\toolchains\msys64\ucrt64\bin\g++.exe")


def body_end(text, start):
    depth, i, state = 0, start, "code"
    while i < len(text):
        a, b = text[i], text[i:i+2]
        if state == "line":
            if a == "\n": state = "code"
        elif state == "comment":
            if b == "*/": state = "code"; i += 1
        elif state in ('"', "'"):
            if a == "\\": i += 1
            elif a == state: state = "code"
        elif b == "//": state = "line"; i += 1
        elif b == "/*": state = "comment"; i += 1
        elif a in ('"', "'"): state = a
        elif a == "{": depth += 1
        elif a == "}":
            depth -= 1
            if depth == 0: return i + 1
        i += 1
    raise RuntimeError("Unterminated C++ function")


def main():
    source = SOURCE.read_text(encoding="utf-8")
    selected = {"read8", "read16", "read32", "write8", "write16", "write32", "add_with_lfags", "sub_with_lfags",
                "adc_with_lfags", "sbc_with_lfags", "mul_with_lfags", "neg_with_lfags", "asr_with_lfags", "lsr_with_lfags",
                "asl_with_lfags", "get_index", "get_extended_operand", "push_val", "pop_val", "take_exception_vector",
                "decode_op", "build_table", "device_reset", "nmi_execute", "interrupt_execute", "execute_run"}
    functions, declarations, instructions = {}, [], []
    pattern = r"^(?:(u8|u16|u32|void|se3208_device::OP) se3208_device::(\w+)\(([^\n]*)\)|INST\((\w+)\))\s*(?://[^\n]*\n\s*)?\{"
    for match in re.finditer(pattern, source, re.M):
        result, method, args, instruction = match.groups()
        name = instruction or method
        if not instruction and name not in selected: continue
        end = body_end(source, source.index("{", match.start(), match.end()))
        functions[name] = source[match.start():end]
        if instruction:
            instructions.append(name); declarations.append(f"    void {name}(u16 opcode);")
        else:
            declarations.append(f"    {result.replace('se3208_device::', '')} {name}({args});")
    missing = selected - functions.keys()
    if missing: raise RuntimeError(f"Missing source functions: {sorted(missing)}")
    enum = re.search(r"enum : u32\s*\{.*?\};", source, re.S).group(0)
    prefix = '''// license:BSD-3-Clause
// copyright-holders:ElSemi
// Generated test-only adaptation; architectural bodies copied from MAME 0.289.
#pragma once
#include <cstdint>
#include <functional>
#include <unordered_map>
#include <vector>
#include <string>
#include <utility>
#include <algorithm>
#include <iterator>
using u8=uint8_t; using u16=uint16_t; using u32=uint32_t; using u64=uint64_t;
using s8=int8_t; using s16=int16_t; using s32=int32_t; using s64=int64_t;
template<class T> constexpr u32 BIT(T value,unsigned bit,unsigned width=1) { return (u32(value) >> (bit & 31)) & (width==32 ? 0xffffffffu : ((1u<<width)-1)); }
namespace util { template<class T> constexpr T sext(T value,unsigned bits) { const u32 sign=1u<<(bits-1);const u32 mask=bits==32?0xffffffffu:((1u<<bits)-1);return T(((u32(value)&mask)^sign)-sign); } }
#define WORD_ALIGNED(a) (((a)&1)==0)
#define DWORD_ALIGNED(a) (((a)&3)==0)
#define WORD_XOR_LE(a) (a)
#define AS_PROGRAM 0
#define CLEAR_LINE 0
#define ASSERT_LINE 1
#define INPUT_LINE_NMI -1
#define LOGMASKED(...) ((void)0)
struct ByteBus {
    std::unordered_map<u32,u8> bytes;
    bool trace_writes=false;
    std::vector<std::pair<u32,u8>> writes;
    std::function<u8(u32)> external_read;
    std::function<void(u32,u8)> external_write;
    u8 read_byte(u32 a) { if(external_read) return external_read(a); auto i=bytes.find(a); return i==bytes.end()?0:i->second; }
    u16 read_word(u32 a,int=0) { return u16(read_byte(a)) | (u16(read_byte(a+1))<<8); }
    u32 read_dword(u32 a) { return u32(read_word(a)) | (u32(read_word(a+2))<<16); }
    void write_byte(u32 a,u8 v) { if(external_write) external_write(a,v); else bytes[a]=v; if(trace_writes) writes.emplace_back(a,v); }
    void write_word(u32 a,u16 v) { write_byte(a,u8(v));write_byte(a+1,u8(v>>8)); }
    void write_dword(u32 a,u32 v) { write_word(a,u16(v));write_word(a+2,u16(v>>16)); }
    void cache(ByteBus&) {}
    void specific(ByteBus&) {}
};
struct DebugMachine { bool side_effects_disabled() {return false;} const char* describe_context() {return "reference";} };
'''
    cls = '''
class se3208_device {
public:
    using OP=void (se3208_device::*)(u16);
    u32 m_R[8]{}; u32 m_PC=0,m_SR=0,m_SP=0,m_ER=0,m_PPC=0;
    u8 m_IRQ=0,m_NMI=0; int m_icount=0;
    ByteBus m_program; ByteBus& m_cache=m_program;
    OP m_optable[65536];
    std::function<void(u8)> m_machinex_cb=[](u8){};
    std::function<u8()> m_iackx_cb=[](){return u8(0);};
    DebugMachine debug_machine;
    DebugMachine& machine() {return debug_machine;}
    ByteBus& space(int) {return m_program;}
    void standard_irq_callback(int,u32) {}
    void debugger_exception_hook(u8) {} void debugger_instruction_hook(u32) {}
    void CLRFLAG(u32 f) {m_SR &= ~f;} void SETFLAG(u32 f) {m_SR |= f;} bool TESTFLAG(u32 f) {return (m_SR&f)!=0;}
    se3208_device() {build_table();}
    void step() {m_icount=1;execute_run();}
'''
    naming = "\n".join(f'        if (m_optable[opcode] == &se3208_device::{name}) return "{name}";' for name in instructions)
    cls += "\n".join(declarations) + '\n    const char* operation_name(u16 opcode) {\n' + naming + '\n        return "UNKNOWN";\n    }\n};\n'
    header = prefix + enum + cls + "\n#define INST(a) void se3208_device::a(u16 opcode)\n" + "\n\n".join(functions.values()) + "\n#undef INST\n"
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "se3208_reference.hpp").write_text(header, encoding="utf-8")
    driver = '''#include "se3208_reference.hpp"
#include <cstdio>
#include <cstring>
#include <memory>
#include <map>
int main(int argc,char** argv) {
    auto c=std::make_unique<se3208_device>();
    if(argc>1 && !std::strcmp(argv[1],"--decode")) {for(unsigned op=0;op<65536;++op)std::printf("%04x,%s\\n",op,c->operation_name(u16(op)));return 0;}
    c->m_program.write_dword(0,0x100);c->device_reset();
    std::map<std::string,unsigned> families;
    for(unsigned op=0;op<65536;++op)++families[c->operation_name(u16(op))];
    std::printf("MAME reference ready: %zu operation families; reset PC=%08x SR=%08x SP=%08x\\n",families.size(),c->m_PC,c->m_SR,c->m_SP);
    for(const auto& [name,count]:families)std::printf("%s:%u ",name.c_str(),count);
    std::puts("");return 0;
}
'''
    (OUT / "main.cpp").write_text(driver, encoding="utf-8")
    command = [str(CXX), "-std=c++17", "-O2", str(OUT / "main.cpp"), "-o", str(OUT / "se3208_reference.exe")]
    build = subprocess.run(command, capture_output=True, text=True)
    (OUT / "build.stdout.txt").write_text(build.stdout)
    (OUT / "build.stderr.txt").write_text(build.stderr)
    if build.returncode:
        print(build.stderr[:5000]); return build.returncode
    run = subprocess.run([str(OUT / "se3208_reference.exe")], capture_output=True, text=True)
    (OUT / "run.stdout.txt").write_text(run.stdout)
    decoder = subprocess.run([str(OUT / "se3208_reference.exe"), "--decode"], capture_output=True, text=True)
    (OUT / "decode.csv").write_text(decoder.stdout)
    report = {"source": str(SOURCE.relative_to(ROOT)).replace("\\", "/"), "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              "extracted_functions": list(functions), "instruction_families": instructions, "adaptation": "test-only byte bus and inert debugger/log hooks; architectural function bodies unchanged",
              "build_command": command, "build_exit": build.returncode, "run_exit": run.returncode, "decode_exit": decoder.returncode,
              "summary": run.stdout, "not_rtl": True}
    (ROOT / "docs/cpu_reference.json").write_text(json.dumps(report, indent=2) + "\n")
    print(run.stdout.splitlines()[0])
    return run.returncode or decoder.returncode


if __name__ == "__main__":
    raise SystemExit(main())
