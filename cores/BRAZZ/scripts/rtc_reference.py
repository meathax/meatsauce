"""Test-only DS1302 serial oracle and bounded game GPIO transaction fixture."""
import csv
import hashlib
import json
from pathlib import Path
from gpu_reference import body

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/"docs/reference/mame/src/devices/machine/ds1302.cpp"

def main():
    text=SOURCE.read_text()
    out=ROOT/"sim/obj_dir/rtc_reference"
    out.mkdir(parents=True,exist_ok=True)
    prefix=r'''// license:BSD-3-Clause
// copyright-holders:Curt Coder
// Test-only serial adapter; the seven MAME serial function bodies below are unchanged.
#pragma once
#include <cstdint>
using u8=uint8_t;
#define LOG(...) ((void)0)
#define BIT(x,n) (((x)>>(n))&1)
enum {STATE_COMMAND,STATE_INPUT,STATE_OUTPUT};
#define COMMAND_READ (m_cmd&1)
#define COMMAND_RAM (m_cmd&0x40)
#define COMMAND_VALID (m_cmd&0x80)
#define COMMAND_BURST (((m_cmd>>1)&31)==31)
#define WRITE_PROTECT (m_reg[7]&0x80)
#define BURST_END (COMMAND_RAM ? m_ram_size:9)
class ds1302_device { public:
    int m_ce=0,m_clk=0,m_io=0,m_state=STATE_COMMAND,m_bits=0;
    u8 m_cmd=0,m_data=0,m_addr=0,m_ram_size=31;
    u8 m_reg[9]{0x80,0,0,1,1,7,0,0,0},m_user[9]{},m_ram[31]{};
    void ce_w(int);void sclk_w(int);void io_w(int);int io_r();
    void load_shift_register();void input_bit();void output_bit();
};
'''
    names=["void ds1302_device::ce_w","void ds1302_device::load_shift_register",
           "void ds1302_device::input_bit","void ds1302_device::output_bit",
           "void ds1302_device::sclk_w","void ds1302_device::io_w","int ds1302_device::io_r"]
    generated=out/"ds1302_reference.hpp"
    generated.write_text(prefix+"\n\n".join(body(text,name) for name in names)+r'''
#undef LOG
#undef BIT
#undef COMMAND_READ
#undef COMMAND_RAM
#undef COMMAND_VALID
#undef COMMAND_BURST
#undef WRITE_PROTECT
#undef BURST_END
''')
    capture=json.loads((ROOT/"docs/mame_gpu_fixture.json").read_text())
    trace=Path(capture["output_directory"])/"mmio.csv"
    count=0
    with trace.open() as src,(out/"gpio.csv").open("w",newline="") as dst:
        reader=csv.DictReader(src);writer=csv.DictWriter(dst,fieldnames=reader.fieldnames);writer.writeheader()
        for row in reader:
            if row["address"] in ["01802004","01802008"]:writer.writerow(row);count+=1
    report={"scope":"test-only MAME serial bodies and captured GPIO sequence under deterministic RTC seed; not full-board acceptance",
            "source_sha256":hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "generated_sha256":hashlib.sha256(generated.read_bytes()).hexdigest(),
            "unchanged_function_bodies":names,"gpio_capture":trace.as_posix(),"gpio_rows":count,
            "gpio_sha256":hashlib.sha256((out/"gpio.csv").read_bytes()).hexdigest(),
            "physical_exceptions":"datasheet tests cover 12h, WP clear, atomic 8-byte clock burst and continuous read, which differ from MAME"}
    (ROOT/"docs/rtc_reference.json").write_text(json.dumps(report,indent=2)+"\n")
    print(f"Generated MAME serial oracle and {count} captured GPIO rows; calendar/physical exceptions use datasheet checks.")
    return 0

if __name__=="__main__":raise SystemExit(main())
