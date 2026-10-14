# Run under Ubuntu WSL from this repository, never execute the ELF in Windows.
ROOT := $(abspath ..)
BUILD := $(ROOT)/sim/build/cpu
RTL := $(ROOT)/rtl
VERILATOR ?= verilator
JOBS ?= 4
CPU_SOURCES := $(RTL)/common/savestate.sv \
 $(RTL)/ucore/v30u_ss_pkg.sv $(RTL)/ucore/v30_core.sv \
 $(RTL)/ucore/v30u_biu.sv $(RTL)/ucore/v30u_ucrom.sv \
 $(RTL)/ucore/v30u_eu.sv $(RTL)/ucore/v30_bus_demux.sv \
 $(ROOT)/sim/zero_cpu_top.sv

.PHONY: cpu cpu-run
cpu: $(BUILD)/Vzero_cpu_top

$(BUILD)/Vzero_cpu_top: $(CPU_SOURCES) $(wildcard $(RTL)/ucore/*.svh) $(ROOT)/sim/main.cpp $(ROOT)/sim/Makefile
	mkdir -p $(BUILD)
	$(VERILATOR) --cc --exe --build -j $(JOBS) --top-module zero_cpu_top \
	 --Mdir $(BUILD) --no-timing -I$(RTL)/ucore -DV30_BACKDOOR \
	 -Wno-fatal -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME \
	 -CFLAGS '-std=c++17 -O2' $(CPU_SOURCES) $(ROOT)/sim/main.cpp

cpu-run: cpu
	mkdir -p $(ROOT)/sim/results
	cd $(ROOT) && $(BUILD)/Vzero_cpu_top \
	 --rom $(ROOT)/roms/regions/maincpu.bin \
	 --output $(ROOT)/sim/results/cpu-boot.json --cycles 3000000 --latency 3
