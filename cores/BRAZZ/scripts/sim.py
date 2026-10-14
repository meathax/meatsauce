"""Native Windows Verilator build/run entry point with bounded failure evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
MSYS = Path(r"D:\vibes\fpga\toolchains\msys64")
VERILATOR = Path(r"D:\vibes\fpga\bin\verilator.exe")
TARGETS = {
    "gpu_fabric": {"top":"cs_gpu_fabric","files":["rtl/video/vr0_pixel_pkg.sv","rtl/cpu/se3208_bus_access.sv","rtl/video/vr0_gpu.sv","rtl/memory/cs_bus_arbiter.sv","rtl/board/cs_address_decode.sv","rtl/video/cs_diagnostic_video.sv","rtl/video/vr0_scanout.sv","donors/sdram/src_v/sdram_axi_core.v","rtl/memory/cs_sdram_backend.sv", "rtl/memory/cs_burst_mux.sv", "rtl/memory/cs_texq.sv","rtl/memory/cs_ddr_rom_backend.sv","rtl/memory/cs_nvram_port.sv","rtl/memory/cs_memory_fabric.sv","sim/video/gpu_fabric.sv"],"main":"sim/video/gpu_fabric.cpp","parameters":["-GMAME_PALETTE_HACK=1"],"dependencies":["sim/memory/sdram_model.hpp","sim/memory/ddr_model.hpp","scripts/gpu_game_fixture.py","docs/mame_gpu_fixture.json","scripts/gpu_frames_fixture.py","docs/mame_gpu_frames.json","sim/obj_dir/gpu_reference/vr0_gpu_reference.hpp"],"acceptance":"Native game packet and whole real MAME frames rendered through the real fabric/SDRAM controller with live scanout and peer load; frame RAM must equal MAME, the display must not underrun; GPU busy clocks per real frame are reported against the 60 Hz budget"},
    "scanout_load": {"top":"cs_scanout_load","files":["rtl/memory/cs_bus_arbiter.sv","rtl/board/cs_address_decode.sv","rtl/video/cs_diagnostic_video.sv","rtl/video/vr0_scanout.sv","donors/sdram/src_v/sdram_axi_core.v","rtl/memory/cs_sdram_backend.sv","rtl/memory/cs_ddr_rom_backend.sv","rtl/memory/cs_nvram_port.sv","rtl/memory/cs_memory_fabric.sv","sim/video/scanout_load.sv"],"main":"sim/video/scanout_load.cpp","parameters":["-GDISPLAY_PRIORITY=1"],"dependencies":["sim/memory/sdram_model.hpp","sim/memory/ddr_model.hpp"],"acceptance":"Synthetic peer-load physical scanout deadline regression only; not game acceptance"},

    "ddr_share": {"top": "cs_ddr_share", "files": ["rtl/memory/cs_ddr_share.sv"], "main": "sim/memory/ddr_share.cpp", "parameters": [], "acceptance": "Fair physical DDR command ownership only"},
    "nvram_host": {"top": "cs_nvram_host", "files": ["rtl/board/cs_nvram_host.sv"], "main": "sim/mister/nvram_host.cpp", "parameters": ["-GWORD_BITS=4"], "acceptance": "HPS protocol and board backup transactions only; not game persistence acceptance"},
    "host_boot": {'top': 'cs_crystal_platform', 'files': ['rtl/cpu/se3208_pkg.sv', 'rtl/cpu/se3208_decode.sv', 'rtl/cpu/se3208_execute.sv', 'rtl/cpu/se3208_bus_access.sv', 'rtl/cpu/se3208_cp_access.sv', 'rtl/cpu/se3208.sv', 'rtl/memory/cs_bus_arbiter.sv', 'rtl/soc/vr0_cp0.sv', 'rtl/soc/vr0_uart.sv', 'rtl/soc/vr0_control.sv', 'rtl/soc/vr0_dma.sv', 'rtl/soc/ds1302.sv', 'rtl/soc/crystal_pic_ram.sv', 'rtl/soc/crystal_pic16.sv', 'rtl/soc/vr0_gpio.sv', 'rtl/video/vr0_pixel_pkg.sv', 'rtl/video/vr0_gpu.sv', 'rtl/video/vr0_crtc.sv', 'rtl/video/vr0_scanout.sv', 'rtl/board/cs_address_decode.sv', 'rtl/board/cs_board_io.sv', 'rtl/board/cs_flash_cmd.sv', 'rtl/audio/vr0_audio_pkg.sv', 'rtl/audio/vr0_voice.sv', 'rtl/audio/vr0_spu.sv', 'rtl/board/cs_boot_probe.sv', 'donors/sdram/src_v/sdram_axi_core.v', 'rtl/memory/cs_sdram_backend.sv', 'rtl/memory/cs_burst_mux.sv', 'rtl/memory/cs_texq.sv', 'rtl/memory/cs_ddr_rom_backend.sv', 'rtl/memory/cs_nvram_port.sv', 'rtl/memory/cs_memory_fabric.sv', 'rtl/board/cs_crystal_board.sv', 'rtl/board/cs_mister_rom_loader.sv', 'rtl/board/cs_crystal_platform.sv'], 'main': 'sim/boot/main.cpp', 'parameters': ['-CFLAGS', '-DCS_PHYSICAL_MEMORY -DCS_HOST_LOADER'], 'dependencies': ['sim/obj_dir/cpu_reference/se3208_reference.hpp', 'docs/rom_image_layout.json', 'sim/boot/board_memory.hpp', 'sim/memory/sdram_model.hpp', 'sim/memory/ddr_model.hpp', 'sim/boot/board_memory.hpp', 'sim/boot/boot_observer.hpp', 'sim/boot/cabinet_input.hpp', 'sim/boot/frame_capture.hpp'], 'acceptance': 'Full original staged-image transfer via actual HPS byte loader and DDR writes, then physical-port cold boot with independent CPU/readback oracle; diagnostic milestones are not pixel-exact gameplay acceptance', 'clock_outputs': {'sdram_clk': {'source': 'clk', 'invert': True}}},
    "mister_rom_loader": {'top': 'cs_mister_rom_loader', 'files': ['rtl/board/cs_mister_rom_loader.sv'], 'main': 'sim/board_io/rom_loader.cpp', 'parameters': ['-GBIOS_BYTES=16'], 'acceptance': 'Host ROM byte packing/physical loader completion only; not game boot acceptance'},
    "physical_boot": {'top': 'cs_crystal_board', 'files': ['rtl/cpu/se3208_pkg.sv', 'rtl/cpu/se3208_decode.sv', 'rtl/cpu/se3208_execute.sv', 'rtl/cpu/se3208_bus_access.sv', 'rtl/cpu/se3208_cp_access.sv', 'rtl/cpu/se3208.sv', 'rtl/memory/cs_bus_arbiter.sv', 'rtl/soc/vr0_cp0.sv', 'rtl/soc/vr0_uart.sv', 'rtl/soc/vr0_control.sv', 'rtl/soc/vr0_dma.sv', 'rtl/soc/ds1302.sv', 'rtl/soc/crystal_pic_ram.sv', 'rtl/soc/crystal_pic16.sv', 'rtl/soc/vr0_gpio.sv', 'rtl/video/vr0_pixel_pkg.sv', 'rtl/video/vr0_gpu.sv', 'rtl/video/vr0_crtc.sv', 'rtl/video/vr0_scanout.sv', 'rtl/board/cs_address_decode.sv', 'rtl/board/cs_board_io.sv', 'rtl/board/cs_flash_cmd.sv', 'rtl/audio/vr0_audio_pkg.sv', 'rtl/audio/vr0_voice.sv', 'rtl/audio/vr0_spu.sv', 'rtl/board/cs_boot_probe.sv', 'donors/sdram/src_v/sdram_axi_core.v', 'rtl/memory/cs_sdram_backend.sv', 'rtl/memory/cs_burst_mux.sv', 'rtl/memory/cs_texq.sv', 'rtl/memory/cs_ddr_rom_backend.sv', 'rtl/memory/cs_nvram_port.sv', 'rtl/memory/cs_memory_fabric.sv', 'rtl/board/cs_crystal_board.sv'], 'main': 'sim/boot/main.cpp', 'parameters': ['-CFLAGS', '-DCS_PHYSICAL_MEMORY'], 'dependencies': ['sim/obj_dir/cpu_reference/se3208_reference.hpp', 'docs/rom_image_layout.json', 'sim/boot/board_memory.hpp', 'sim/memory/sdram_model.hpp', 'sim/memory/ddr_model.hpp', 'sim/boot/board_memory.hpp', 'sim/boot/boot_observer.hpp', 'sim/boot/cabinet_input.hpp', 'sim/boot/frame_capture.hpp'], 'acceptance': 'Original-ROM full board with physical SDRAM/DDR models and independent CPU/readback checks; packet milestone is diagnostic, not pixel-exact gameplay acceptance', 'clock_outputs': {'sdram_clk': {'source': 'clk', 'invert': True}}},
    "memory_fabric": {"top": "cs_memory_fabric", "files": ["donors/sdram/src_v/sdram_axi_core.v", "rtl/memory/cs_sdram_backend.sv", "rtl/memory/cs_ddr_rom_backend.sv", "rtl/memory/cs_nvram_port.sv", "rtl/memory/cs_memory_fabric.sv"], "main": "sim/memory/fabric.cpp", "parameters": ["-GCLEAR_LAST=23'h0000fc", "-GTEST_LAST=14'h003f"], "dependencies": ["sim/memory/sdram_model.hpp", "sim/memory/ddr_model.hpp", "sim/boot/board_memory.hpp"], "clock_outputs": {"sdram_clk": {"source": "clk", "invert": True}}, "acceptance": "Integrated physical memory map/transport only; not game acceptance"},
    "ddr_rom": {"top": "cs_ddr_rom_backend", "files": ["rtl/memory/cs_ddr_rom_backend.sv"], "main": "sim/memory/ddr_rom.cpp", "parameters": [], "dependencies": ["sim/memory/ddr_model.hpp"], "acceptance": "MiSTer DDR ROM/loader transport only; not game acceptance"},
    "sdram": {"top": "cs_sdram_backend", "files": ["donors/sdram/src_v/sdram_axi_core.v", "rtl/memory/cs_sdram_backend.sv"], "main": "sim/memory/sdram.cpp", "parameters": [], "dependencies": ["sim/memory/sdram_model.hpp"], "clock_outputs": {"sdram_clk": {"source": "clk", "invert": True}}, "acceptance": "Physical SDRAM command/timing transport only; not game acceptance"},
    "sdram_timed": {"top": "cs_sdram_backend", "files": ["donors/sdram/src_v/sdram_axi_core.v", "rtl/memory/cs_sdram_backend.sv"], "main": "sim/memory/sdram_timed.cpp", "parameters": [], "dependencies": ["sim/memory/sdram_model.hpp"], "clock_outputs": {"sdram_clk": {"source": "clk", "invert": True}}, "acceptance": "Delayed chip/board/input-pad profiles on the real SDRAM controller; not game or production signoff"},
    "sdram_capture": {"top": "cs_sdram_backend", "files": ["donors/sdram/src_v/sdram_axi_core.v", "rtl/memory/cs_sdram_backend.sv"], "main": "sim/memory/sdram_timed.cpp", "parameters": ["-GPHASED_CAPTURE=1"], "dependencies": ["sim/memory/sdram_model.hpp"], "clock_outputs": {"sdram_clk": {"source": "clk", "invert": True}}, "acceptance": "Earlier input capture under eight delayed chip/pad profiles; requires production PLL/I/O/CDC timing qualification"},
    "sdram_registered": {"top": "cs_sdram_backend", "files": ["donors/sdram/src_v/sdram_axi_core.v", "rtl/memory/cs_sdram_backend.sv"], "main": "sim/memory/sdram_timed.cpp", "parameters": ["-GREGISTERED_IO=1", "-CFLAGS", "-DCS_SDRAM_REGISTERED_IO=1"], "dependencies": ["sim/memory/sdram_model.hpp"], "clock_outputs": {"sdram_clk": {"source": "clk", "invert": False}}, "acceptance": "Registered pins and in-phase clock; requires source-matched fitted profiles and production I/O closure"},
"address_decode": {"top": "cs_decode_policy_bench", "files": ["rtl/board/cs_address_decode.sv", "sim/address_decode/bench.sv"], "main": "sim/address_decode/main.cpp", "parameters": []},
"spu": {"top": "vr0_spu", "files": ["rtl/audio/vr0_audio_pkg.sv", "rtl/audio/vr0_voice.sv", "rtl/audio/vr0_spu.sv"], "main": "sim/audio/spu.cpp", "parameters": ["-CFLAGS", "-fwrapv"],
"dependencies": ["scripts/spu_reference.py", "scripts/gpu_reference.py", "docs/reference/mame/src/devices/sound/vrender0.cpp", "sim/obj_dir/spu_reference/spu_reference.hpp", "sim/obj_dir/spu_reference/initial_voices.csv", "docs/mame_audio_fixture.json"]},
"voice": {"top": "vr0_voice", "files": ["rtl/audio/vr0_audio_pkg.sv", "rtl/audio/vr0_voice.sv"], "main": "sim/audio/voice.cpp", "parameters": ["-CFLAGS", "-fwrapv"],
"dependencies": ["scripts/spu_reference.py", "scripts/gpu_reference.py", "docs/reference/mame/src/devices/sound/vrender0.cpp", "sim/obj_dir/spu_reference/spu_reference.hpp", "sim/obj_dir/spu_reference/initial_voices.csv", "docs/mame_audio_fixture.json"]},
"crtc": {"top": "vr0_crtc", "files": ["rtl/video/vr0_crtc.sv"], "main": "sim/video/crtc.cpp", "parameters": [],
"dependencies": ["scripts/crtc_reference.py", "scripts/gpu_reference.py", "docs/reference/mame/src/devices/machine/vrender0.cpp", "docs/mame_gpu_fixture.json", "sim/obj_dir/crtc_reference/crtc_reference.hpp", "sim/obj_dir/crtc_reference/crtc.csv"]},
    "gpio": {"top": "vr0_gpio", "files": ["rtl/soc/ds1302.sv", "rtl/soc/crystal_pic_ram.sv", "rtl/soc/crystal_pic16.sv", "rtl/soc/vr0_gpio.sv"], "main": "sim/soc/gpio.cpp", "parameters": ["-GSECOND_CYCLES=64"],
             "dependencies": ["sim/obj_dir/rtc_reference/ds1302_reference.hpp", "sim/obj_dir/rtc_reference/gpio.csv", "scripts/rtc_reference.py", "scripts/gpu_reference.py", "docs/reference/mame/src/devices/machine/ds1302.cpp", "docs/mame_gpu_fixture.json"]},
    "arbiter_preempt": {"top": "cs_bus_arbiter", "files": ["rtl/memory/cs_bus_arbiter.sv"], "main": "sim/arbiter/preempt.cpp", "parameters": ["-GCLIENTS=5","-GPRIORITY_CLIENT=4","-GSECOND_PRIORITY_CLIENT=3","-GPRIORITY_BURST=4","-GREGISTER_GRANT=1","-GPREEMPT_AGE=24"]},
    "arbiter5": {"top": "cs_bus_arbiter", "files": ["rtl/memory/cs_bus_arbiter.sv"], "main": "sim/arbiter/five.cpp", "parameters": ["-GCLIENTS=5"]},
    "arbiter4": {"top": "cs_bus_arbiter", "files": ["rtl/memory/cs_bus_arbiter.sv"], "main": "sim/arbiter/four.cpp", "parameters": ["-GCLIENTS=4"]},
    "arbiter3": {"top": "cs_bus_arbiter", "files": ["rtl/memory/cs_bus_arbiter.sv"], "main": "sim/arbiter/three.cpp", "parameters": ["-GCLIENTS=3"]},
    "board_io": {"top": "cs_board_io", "files": ["rtl/board/cs_board_io.sv"], "main": "sim/board_io/main.cpp", "parameters": []},
    "scanout": {"top": "vr0_scanout", "files": ["rtl/video/vr0_scanout.sv"], "main": "sim/video/scanout.cpp", "parameters": [], "dependencies": ["scripts/gpu_reference.py", "sim/obj_dir/gpu_reference/vr0_gpu_reference.hpp", "docs/gpu_game_replay_results.json"]},
    "gpu_game": {"top": "vr0_gpu", "files": ["rtl/video/vr0_pixel_pkg.sv", "rtl/cpu/se3208_bus_access.sv", "rtl/video/vr0_gpu.sv"],
            "main": "sim/video/gpu_game.cpp", "parameters": ["-GMAME_PALETTE_HACK=1"],
            "dependencies": ["sim/video/gpu.cpp", "scripts/gpu_game_fixture.py", "docs/mame_gpu_fixture.json", "sim/obj_dir/gpu_reference/vr0_gpu_reference.hpp", "scripts/gpu_reference.py", "docs/reference/mame/src/devices/video/vrender0.cpp", "docs/reference/mame/src/devices/video/vrender0.h"]},    "gpu": {"top": "vr0_gpu", "files": ["rtl/video/vr0_pixel_pkg.sv", "rtl/cpu/se3208_bus_access.sv", "rtl/video/vr0_gpu.sv"],
            "main": "sim/video/gpu.cpp", "parameters": ["-GMAME_PALETTE_HACK=1"],
            "dependencies": ["sim/obj_dir/gpu_reference/vr0_gpu_reference.hpp", "scripts/gpu_reference.py", "docs/reference/mame/src/devices/video/vrender0.cpp", "docs/reference/mame/src/devices/video/vrender0.h"]},
    "bus": {"top": "cs_bus_ram", "files": ["rtl/board/cs_bus_pkg.sv", "rtl/memory/cs_bus_ram.sv"],
            "main": "sim/bus/main.cpp", "parameters": ["-GWORD_ADDR_BITS=4", "-GACCESS_CYCLES=3"]},
    "cpu_decode": {"top": "se3208_decode", "files": ["rtl/cpu/se3208_pkg.sv", "rtl/cpu/se3208_decode.sv"],
                   "main": "sim/cpu_decode/main.cpp", "parameters": [],
                   "dependencies": ["sim/obj_dir/cpu_reference/decode.csv", "sim/obj_dir/isa_research/vendor_bin/control_family.csv", "scripts/se3208_vendor_probe.py", "docs/se3208_vendor_tools.json"]},
    "cpu_execute": {"top": "se3208_execute", "files": ["rtl/cpu/se3208_pkg.sv", "rtl/cpu/se3208_decode.sv", "rtl/cpu/se3208_execute.sv"],
                    "main": "sim/cpu_execute/main.cpp", "parameters": [],
                    "dependencies": ["sim/obj_dir/cpu_reference/se3208_reference.hpp"]},
    "flash_cmd": {"top": "cs_flash_cmd", "files": ["rtl/board/cs_flash_cmd.sv"],
                  "main": "sim/flash_cmd/main.cpp", "parameters": [],
                  "acceptance": "Pinned Crystal System cartridge command/query behavior; NOR erase/program timing not implemented"},
    "cp0": {"top": "vr0_cp0", "files": ["rtl/soc/vr0_cp0.sv"],
            "main": "sim/cp0/main.cpp", "parameters": [],
            "acceptance": "Qualified CP0 register profile and write-through cache; physical descriptor/timing and write-back remain open"},
    "cpu_control": {"top": "se3208", "files": ["rtl/cpu/se3208_pkg.sv", "rtl/cpu/se3208_decode.sv", "rtl/cpu/se3208_execute.sv", "rtl/cpu/se3208_bus_access.sv", "rtl/cpu/se3208_cp_access.sv", "rtl/cpu/se3208.sv"],
                    "main": "sim/cpu_control/main.cpp", "parameters": [],
                    "acceptance": "Primary-evidence MVTC/MVFC transport and R0 effects; synthetic coprocessor, not game boot/control-device acceptance"},
    "cpu": {"top": "se3208", "files": ["rtl/cpu/se3208_pkg.sv", "rtl/cpu/se3208_decode.sv", "rtl/cpu/se3208_execute.sv", "rtl/cpu/se3208_bus_access.sv", "rtl/cpu/se3208_cp_access.sv", "rtl/cpu/se3208.sv"],
            "main": "sim/cpu/main.cpp", "parameters": ["-GENABLE_STATE_LOAD=1", "-GINVALID_OP_NOP=1"],
            "dependencies": ["sim/obj_dir/cpu_reference/se3208_reference.hpp", "sim/obj_dir/isa_research/vendor_bin/control_family.csv"]},
    "cpu_board": {"top": "se3208", "files": ["rtl/cpu/se3208_pkg.sv", "rtl/cpu/se3208_decode.sv", "rtl/cpu/se3208_execute.sv", "rtl/cpu/se3208_bus_access.sv", "rtl/cpu/se3208_cp_access.sv", "rtl/cpu/se3208.sv"],
            "main": "sim/cpu/main.cpp", "parameters": ["-GENABLE_STATE_LOAD=1", "-GINVALID_OP_NOP=1", "-GCE_CATCHUP=1", "-GFETCH_PAIR=1", "-GFAST_BUS=1", "-GPREFETCH=1"],
            "dependencies": ["sim/obj_dir/cpu_reference/se3208_reference.hpp", "sim/obj_dir/isa_research/vendor_bin/control_family.csv"],
            "acceptance": "Same differential CPU suite with the board's throughput parameters (CE catch-up, paired fetch, bus pass-through, prefetch)"},
    "cp0_board": {"top": "vr0_cp0", "files": ["rtl/soc/vr0_cp0.sv"],
            "main": "sim/cp0/main.cpp", "parameters": ["-GPOSTED_WRITES=1", "-GCACHE_WHILE_DISABLED=1", "-CFLAGS", "-DCS_CP0_POSTED"],
            "acceptance": "CP0 cache with the board's posted write FIFO and cache-while-disabled options"},
    "bios_sound": {"top": "cs_boot_probe", "files": ["rtl/memory/cs_burst_mux.sv", "rtl/memory/cs_texq.sv", "rtl/cpu/se3208_pkg.sv", "rtl/cpu/se3208_decode.sv", "rtl/cpu/se3208_execute.sv", "rtl/cpu/se3208_bus_access.sv", "rtl/cpu/se3208_cp_access.sv", "rtl/cpu/se3208.sv", "rtl/memory/cs_bus_arbiter.sv", "rtl/soc/vr0_cp0.sv", "rtl/soc/vr0_uart.sv", "rtl/soc/vr0_control.sv", "rtl/soc/vr0_dma.sv", "rtl/soc/ds1302.sv", "rtl/soc/crystal_pic_ram.sv", "rtl/soc/crystal_pic16.sv", "rtl/soc/vr0_gpio.sv", "rtl/video/vr0_pixel_pkg.sv", "rtl/video/vr0_gpu.sv", "rtl/video/vr0_crtc.sv", "rtl/video/vr0_scanout.sv", "rtl/board/cs_address_decode.sv", "rtl/board/cs_board_io.sv", "rtl/board/cs_flash_cmd.sv", "rtl/audio/vr0_audio_pkg.sv", "rtl/audio/vr0_voice.sv", "rtl/audio/vr0_spu.sv", "rtl/board/cs_boot_probe.sv"],
                   "main": "sim/boot/main.cpp", "extra_sources": ["sim/boot/sound_fixture_oracle.cpp"], "parameters": ["-CFLAGS", "-DCS_SOUND_FIXTURE -fwrapv"],
                   "dependencies": ["sim/obj_dir/cpu_reference/se3208_reference.hpp", "docs/rom_image_layout.json", "sim/boot/board_memory.hpp", "sim/boot/sound_fixture.hpp", "sim/boot/sound_fixture_oracle.cpp", "sim/obj_dir/spu_reference/spu_reference.hpp"],
                   "acceptance": "CPU-driven synthetic sound BIOS integration; not game cold-boot acceptance"},    "boot_probe": {"top": "cs_boot_probe", "files": ["rtl/cpu/se3208_pkg.sv", "rtl/cpu/se3208_decode.sv", "rtl/cpu/se3208_execute.sv", "rtl/cpu/se3208_bus_access.sv", "rtl/cpu/se3208_cp_access.sv", "rtl/cpu/se3208.sv", "rtl/memory/cs_bus_arbiter.sv", "rtl/soc/vr0_cp0.sv", "rtl/soc/vr0_uart.sv", "rtl/soc/vr0_control.sv", "rtl/soc/vr0_dma.sv", "rtl/soc/ds1302.sv", "rtl/soc/crystal_pic_ram.sv", "rtl/soc/crystal_pic16.sv", "rtl/soc/vr0_gpio.sv", "rtl/video/vr0_pixel_pkg.sv", "rtl/video/vr0_gpu.sv", "rtl/video/vr0_crtc.sv", "rtl/video/vr0_scanout.sv", "rtl/board/cs_address_decode.sv", "rtl/board/cs_board_io.sv", "rtl/board/cs_flash_cmd.sv", "rtl/audio/vr0_audio_pkg.sv", "rtl/audio/vr0_voice.sv", "rtl/audio/vr0_spu.sv", "rtl/board/cs_boot_probe.sv"],
                   "main": "sim/boot/main.cpp", "parameters": [],
                   "dependencies": ["sim/obj_dir/cpu_reference/se3208_reference.hpp", "docs/rom_image_layout.json", "sim/boot/board_memory.hpp"],
                   "acceptance": "diagnostic CPU BIOS probe with observed chip inputs; active chips validated separately; not full-board/game acceptance"},
    "control": {"top": "vr0_control", "files": ["rtl/soc/vr0_uart.sv", "rtl/soc/vr0_control.sv"],
                "main": "sim/soc/control.cpp", "parameters": []},
    "dma": {"top": "vr0_dma", "files": ["rtl/cpu/se3208_bus_access.sv", "rtl/soc/vr0_dma.sv"],
            "main": "sim/soc/dma.cpp", "parameters": [],
            "dependencies": ["sim/obj_dir/dma_reference/vr0_reference.hpp", "sim/obj_dir/cpu_reference/se3208_reference.hpp", "scripts/dma_reference.py"]},
    "arbiter": {"top": "cs_bus_arbiter", "files": ["rtl/memory/cs_bus_arbiter.sv"], "main": "sim/arbiter/main.cpp", "parameters": []}
}

TARGETS['host_checkpoint']={**TARGETS['host_boot'],
    'parameters':['--savable','-CFLAGS','-DCS_PHYSICAL_MEMORY -DCS_HOST_LOADER -DCS_CHECKPOINT'],
    'dependencies':[*TARGETS['host_boot']['dependencies'],'sim/boot/checkpoint.hpp'],
    'acceptance':'Exact-source full RTL/physical-memory/reference/cabinet checkpoint continuation; final acceptance still requires separate cold boot'}


TARGETS['arbiter_realtime']={'top':'cs_bus_arbiter','files':['rtl/memory/cs_bus_arbiter.sv'],'main':'sim/arbiter/realtime.cpp','parameters':['-GCLIENTS=5','-GPRIORITY_CLIENT=4','-GSECOND_PRIORITY_CLIENT=3','-GPRIORITY_BURST=4'],'acceptance':'Bounded sound/display shared-memory service under persistent contention; unit proof, not game audio acceptance'}
TARGETS['arbiter_registered']={**TARGETS['arbiter'],'parameters':['-GREGISTER_GRANT=1'],'acceptance':'Owned registered grant, randomized requests/replies and locked backpressure; no game acceptance'}
TARGETS['arbiter_realtime_registered']={**TARGETS['arbiter_realtime'],'parameters':[*TARGETS['arbiter_realtime']['parameters'],'-GREGISTER_GRANT=1']}

TARGETS['host_timed_checkpoint']={**TARGETS['host_checkpoint'],
    'parameters':['--savable','-GSDRAM_REGISTERED_IO=1','-GSDRAM_PHASED_CAPTURE=1','-CFLAGS','-DCS_PHYSICAL_MEMORY -DCS_HOST_LOADER -DCS_CHECKPOINT -DCS_TIMED_SDRAM -DCS_SDRAM_LATE_CAPTURE'],
    'dependencies':[*TARGETS['host_checkpoint']['dependencies'],'sim/memory/sdram_timed_port.hpp'],
    'acceptance':'Registered physical SDRAM pins, fitted chip/pad/board-return timing, real host load and savable cold boot; complete game acceptance requires recorded native frames and controls'}
TARGETS['gpu_fabric_wordscan']={**TARGETS['gpu_fabric'],'parameters':[*TARGETS['gpu_fabric']['parameters'],'-GSCAN_BURST=0'],
    'acceptance':'Diagnostic: legacy word-by-word scanout under the same load (display deadline comparison)'}
TARGETS['texq']={'top':'cs_texq','files':['rtl/memory/cs_texq.sv'],'main':'sim/memory/texq.cpp','parameters':[],
    'acceptance':'Ordered texture write queue: in-order drain behind the renderer, front ordering, read-after-write hold, pass-through'}
TARGETS['sdram_phased']={**TARGETS['sdram_registered'],
    'parameters':['-GREGISTERED_IO=1','-GPHASED_CAPTURE=1','-CFLAGS','-DCS_SDRAM_REGISTERED_IO -DCS_SDRAM_LATE_CAPTURE'],
    'dependencies':list(TARGETS['sdram_registered']['dependencies']),
    'acceptance':'Actual registered pins and dedicated capture clock; requires fitted capture phase, all eight endpoints and formal cross-clock timing'}
for timing_target in ('sdram_timed','sdram_capture','sdram_registered','sdram_phased'):
    TARGETS[timing_target]['dependencies'].append('sim/memory/sdram_timed_port.hpp')

for provenance_target in TARGETS.values():
    if provenance_target.get('main')=='sim/boot/main.cpp':
        provenance_target['dependencies']=[*provenance_target.get('dependencies',[]),'sim/boot/scanout_source.hpp']
TARGETS['scanout']['dependencies'].extend(['sim/boot/scanout_source.hpp','sim/boot/frame_capture.hpp'])

TARGETS['gpu_hw']={'top':'vr0_gpu','files':['rtl/video/vr0_pixel_pkg.sv','rtl/cpu/se3208_bus_access.sv','rtl/video/vr0_gpu.sv'],
    'main':'sim/video/gpu_hw.cpp','parameters':[],
    'dependencies':['sim/video/gpu.cpp','sim/obj_dir/gpu_reference/vr0_gpu_reference.hpp','scripts/gpu_reference.py','docs/reference/mame/src/devices/video/vrender0.cpp','docs/reference/mame/src/devices/video/vrender0.h'],
    'acceptance':'Hardware-correct palette/transparency (MAME_PALETTE_HACK=0 default) vs explicit expectations; differs from MAME only in predicted pixels'}
TARGETS['video_calc']={'top':'video_calc','files':['rtl/mister/hps_io.sv'],'main':'sim/mister/video_calc.cpp','parameters':[],
    'acceptance':'Real HPS video counter period measurement across asynchronous phases; digital CDC behavior only, not metastability or game acceptance'}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", choices=TARGETS)
    parser.add_argument("--run-only", action="store_true")
    args, extra = parser.parse_known_args()
    target = dict(TARGETS[args.target])
    if args.target in ('sdram_timed','sdram_capture','sdram_registered','sdram_phased','host_timed_checkpoint') and os.environ.get('CS_SDRAM_TIMING_PROFILE'):
        profile_path=Path(os.environ['CS_SDRAM_TIMING_PROFILE']).resolve()
        target['timing_profile']={'path':str(profile_path),'sha256':hashlib.sha256(profile_path.read_bytes()).hexdigest(),
                                  'name':os.environ.get('CS_SDRAM_TIMING_PROFILE_NAME','all-eight')}
    if args.target in ('sdram_phased','host_timed_checkpoint'):
        phase_text=os.environ.get('CS_SDRAM_CAPTURE_PHASE_NS')
        if not phase_text or not 0<float(phase_text)<11.64 or 'timing_profile' not in target:
            parser.error('phased SDRAM targets require explicit fitted profile and positive capture phase below half a period')
        target['timing_profile']['capture_phase_ns']=phase_text
    if args.target=='host_timed_checkpoint' and ('timing_profile' not in target or target['timing_profile']['name']=='all-eight'):
        parser.error('host_timed_checkpoint requires CS_SDRAM_TIMING_PROFILE and CS_SDRAM_TIMING_PROFILE_NAME')
    if args.target in ("voice", "spu", "bios_sound") and not args.run_only:
        oracle = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/spu_reference.py")], cwd=ROOT)
        if oracle.returncode: return oracle.returncode
    if args.target == "crtc" and not args.run_only:
        oracle = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/crtc_reference.py")], cwd=ROOT)
        if oracle.returncode: return oracle.returncode
    if args.target == "gpio" and not args.run_only:
        oracle = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/rtc_reference.py")], cwd=ROOT)
        if oracle.returncode: return oracle.returncode
    if args.target in ("gpu_game","gpu_fabric") and not args.run_only:
        fixture = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/gpu_game_fixture.py")], cwd=ROOT)
        if fixture.returncode: return fixture.returncode
    if args.target == "gpu_fabric" and not args.run_only:
        frames = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/gpu_frames_fixture.py")], cwd=ROOT)
        if frames.returncode: return frames.returncode
    if args.target in ("gpu", "gpu_game", "gpu_hw", "scanout", "gpu_fabric") and not args.run_only:
        oracle = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/gpu_reference.py")], cwd=ROOT)
        if oracle.returncode: return oracle.returncode
    if args.target == "cpu_decode" and not args.run_only:
        vendor_oracle = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/se3208_vendor_probe.py")], cwd=ROOT)
        if vendor_oracle.returncode: return vendor_oracle.returncode
    if (args.target.startswith("cpu") or args.target in ["boot_probe", "bios_sound", "dma"]) and not args.run_only:
        oracle = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/cpu_reference.py")], cwd=ROOT)
        if oracle.returncode: return oracle.returncode
    if args.target == "dma" and not args.run_only:
        oracle = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/dma_reference.py")], cwd=ROOT)
        if oracle.returncode: return oracle.returncode
    if args.target == "boot_probe" and not args.run_only:
        staging = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "scripts/stage_roms.py")], cwd=ROOT)
        if staging.returncode: return staging.returncode
    out = ROOT / "sim/obj_dir" / args.target
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = str(MSYS / "ucrt64/bin") + os.pathsep + str(MSYS / "usr/bin") + os.pathsep + env.get("PATH", "")
    build_sources = [ROOT / file for file in target["files"]] + [ROOT / target["main"]] + [ROOT / file for file in target.get("extra_sources", [])]
    sources = build_sources + [ROOT / file for file in target.get("dependencies", [])]
    if args.target.startswith("cpu") or args.target in ("boot_probe", "bios_sound"):
        sources += [ROOT / "scripts/cpu_reference.py", ROOT / "docs/reference/mame/src/devices/cpu/se3208/se3208.cpp"]
    if args.target in ("boot_probe", "bios_sound"):
        sources += [ROOT / "scripts/stage_roms.py", ROOT / "roms/images/bios.bin", ROOT / "roms/images/crysking.bin"]
    if args.target in ("boot_probe", "bios_sound"):
        sources += [ROOT / "sim/boot/board_memory.hpp"]
    if args.target == "boot_probe":
        sources += [ROOT / "sim/boot/boot_observer.hpp", ROOT / "sim/boot/frame_capture.hpp", ROOT / "sim/boot/cabinet_input.hpp"]
    if args.target == "bios_sound":
        sources += [ROOT / "sim/boot/sound_fixture.hpp"]
    signatures = [{"path": str(p.relative_to(ROOT)).replace("\\", "/"), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in sources]
    if args.target in ('host_checkpoint','host_timed_checkpoint'):
        identity_sources=signatures+[{"path":name,"sha256":hashlib.sha256((ROOT/name).read_bytes()).hexdigest()}
                                    for name in ['roms/images/bios.bin','roms/images/crysking.bin']]
        identity=hashlib.sha256(json.dumps({'target':target,'sources':identity_sources},sort_keys=True).encode()).hexdigest()
        header=out/'identity.hpp'
        header.write_text('#pragma once\nstatic constexpr const char* CS_CHECKPOINT_ID="'+identity+'";\n')
        signatures.append({'path':header.relative_to(ROOT).as_posix(),'sha256':hashlib.sha256(header.read_bytes()).hexdigest()})
    workspace_record = out / "workspace.json"
    if args.run_only:
        if not workspace_record.is_file():
            print("No previous build workspace for this target"); return 2
        saved = json.loads(workspace_record.read_text())
        if saved["sources"] != signatures or saved["target"] != target:
            print("Sources/build parameters changed; rebuild instead of running a stale model"); return 2
        workspace = Path(saved["workspace"])
    else:
        env["VERILATOR_PROJECT"] = "CrystalSystem"
        allocation = subprocess.run([str(VERILATOR), "workspace"], cwd=ROOT, env=env, capture_output=True, text=True)
        if allocation.returncode:
            print(allocation.stderr.strip()); return allocation.returncode
        workspace = Path(allocation.stdout.strip())
        workspace_record.write_text(json.dumps({"workspace": str(workspace), "sources": signatures, "target": target}, indent=2) + "\n")
    env["VERILATOR_WORKSPACE"] = str(workspace)
    model_dir = workspace / "obj_dir"
    model_dir.mkdir(parents=True, exist_ok=True)
    commands = []
    if not args.run_only:
        command = [str(VERILATOR), "--cc", "--exe", "--build", "-j", "4", "-O3", "--top-module", target["top"],
                   "--Mdir", model_dir.as_posix(), "-CFLAGS", "-O2", "-MAKEFLAGS", "OPT_FAST=-O2", "-MAKEFLAGS", "OPT_GLOBAL=-O2",
                   "-Wno-fatal", *target["parameters"], *(p.as_posix() for p in build_sources)]
        commands.append(command)
        with (out / "build.log").open("w", encoding="utf-8") as log:
            build = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        if build.returncode:
            lines = (out / "build.log").read_text(encoding="utf-8", errors="replace").splitlines()
            failures = [line for line in lines if any(word in line for word in ["%Error", "error:", "Error ", "FAIL"])]
            print("\n".join((failures or lines[-16:])[:24]))
            print(f"build exit={build.returncode}; exact log: {out / 'build.log'}")
            return build.returncode
    executable = model_dir / ("V" + target["top"] + ".exe")
    if not executable.is_file():
        print(f"Missing native simulator executable: {executable}"); return 2
    command = [str(VERILATOR), "sim", str(executable), *extra]
    commands.append(command)
    begin = time.monotonic()
    run = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
    (out / "run.stdout.txt").write_text(run.stdout, encoding="utf-8")
    (out / "run.stderr.txt").write_text(run.stderr, encoding="utf-8")
    report = {"target": args.target, "acceptance": target.get("acceptance", "unit verification"), "runtime": "native Windows PE / MSYS2 UCRT64", "commands": commands,
              "exit_code": run.returncode, "run_seconds": time.monotonic() - begin,
              "sources": signatures, "workspace": str(workspace), "timing_profile": target.get("timing_profile"),
              "stdout": run.stdout, "stderr": run.stderr, "build_log": str((out / "build.log").relative_to(ROOT))}
    report_path = ROOT / "docs" / ("simulation_" + args.target + ".json")
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(run.stdout.strip())
    if run.stderr: print(run.stderr.strip(), file=sys.stderr)
    print(f"exit={run.returncode}; evidence={report_path.relative_to(ROOT)}")
    return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
