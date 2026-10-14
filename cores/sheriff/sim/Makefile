# Linux tools are run explicitly in Ubuntu WSL from the project root.
ROOT := $(abspath ..)
BUILD ?= $(ROOT)/sim/build
VERILATOR ?= verilator
VFLAGS := -Wall -Wno-fatal --cc --exe --build -j 4 -I$(ROOT)/rtl -CFLAGS "-O2 -std=c++17"
CPU_RTL := $(ROOT)/rtl/n8080_cpu.sv $(ROOT)/rtl/n8080_vm80a_ce.v
.PHONY: cpu cpu-timing phase board service mcs48 sn controls video video-register hiscore rotation scaling flip gamma-guard clean
cpu:
	mkdir -p $(BUILD)/cpu
	$(VERILATOR) $(VFLAGS) --top-module n8080_cpu --Mdir $(BUILD)/cpu $(CPU_RTL) $(ROOT)/sim/cpu_qualification.cpp >$(BUILD)/cpu/build.log 2>&1
	cd $(BUILD)/cpu && ./Vn8080_cpu
cpu-timing:
	mkdir -p $(BUILD)/cpu-timing
	$(VERILATOR) $(VFLAGS) --top-module n8080_cpu --Mdir $(BUILD)/cpu-timing $(CPU_RTL) $(ROOT)/sim/cpu_timing.cpp >$(BUILD)/cpu-timing/build.log 2>&1
	cd $(BUILD)/cpu-timing && ./Vn8080_cpu
clean:
	@echo "Build products are ignored; keep failed evidence until diagnosis is complete."

phase:
	mkdir -p $(BUILD)/phase
	$(VERILATOR) $(VFLAGS) --top-module vm80a_phase --Mdir $(BUILD)/phase $(ROOT)/sim/vm80a_phase.sv $(ROOT)/rtl/vendor/vm80a/vm80a.v $(ROOT)/sim/phase_qualification.cpp >$(BUILD)/phase/build.log 2>&1
	cd $(BUILD)/phase && ./Vvm80a_phase
board:
	mkdir -p $(BUILD)/board
	$(VERILATOR) $(VFLAGS) --top-module n8080_board --Mdir $(BUILD)/board $(ROOT)/rtl/n8080_board.sv $(CPU_RTL) $(ROOT)/rtl/n8080_mcs48.sv $(ROOT)/rtl/vendor/t48/t48_core.v $(ROOT)/rtl/sheriff_sn76477.sv $(ROOT)/sim/board_harness.cpp >$(BUILD)/board/build.log 2>&1
service:
	mkdir -p $(BUILD)/service
	$(VERILATOR) $(VFLAGS) --top-module n8080_board --Mdir $(BUILD)/service $(ROOT)/rtl/n8080_board.sv $(CPU_RTL) $(ROOT)/rtl/n8080_mcs48.sv $(ROOT)/rtl/vendor/t48/t48_core.v $(ROOT)/rtl/sheriff_sn76477.sv $(ROOT)/sim/service_qualification.cpp >$(BUILD)/service/build.log 2>&1
	cd $(BUILD)/service && ./Vn8080_board
mcs48:
	mkdir -p $(BUILD)/mcs48
	$(VERILATOR) $(VFLAGS) --top-module n8080_mcs48 --Mdir $(BUILD)/mcs48 $(ROOT)/rtl/n8080_mcs48.sv $(ROOT)/rtl/vendor/t48/t48_core.v $(ROOT)/sim/mcs48_qualification.cpp >$(BUILD)/mcs48/build.log 2>&1
	cd $(BUILD)/mcs48 && ./Vn8080_mcs48 $(ROOT)/roms/sheriff/sh.snd
sn:
	mkdir -p $(BUILD)/sn
	$(VERILATOR) $(VFLAGS) --top-module sheriff_sn76477 --Mdir $(BUILD)/sn $(ROOT)/rtl/sheriff_sn76477.sv $(ROOT)/sim/sn_qualification.cpp >$(BUILD)/sn/build.log 2>&1
	cd $(BUILD)/sn && ./Vsheriff_sn76477
controls:
	mkdir -p $(BUILD)/controls
	$(VERILATOR) $(VFLAGS) --top-module n8080_controls --Mdir $(BUILD)/controls $(ROOT)/rtl/n8080_controls.sv $(ROOT)/sim/controls_qualification.cpp >$(BUILD)/controls/build.log 2>&1
	cd $(BUILD)/controls && ./Vn8080_controls
video:
	mkdir -p $(BUILD)/video
	sed -n '/^module sync_fix/,/^endmodule/p' $(ROOT)/sys/sys_top.v >$(BUILD)/video/sync_fix.v
	$(VERILATOR) $(VFLAGS) -Wno-PROCASSWIRE -Wno-BLKANDNBLK --top-module n8080_video --Mdir $(BUILD)/video $(ROOT)/rtl/n8080_video.sv $(ROOT)/rtl/n8080_gamma_guard.sv $(ROOT)/rtl/n8080_video_mixer.sv $(ROOT)/rtl/n8080_crt_adjust.sv $(ROOT)/sys/scandoubler.v $(ROOT)/sys/hq2x.sv $(ROOT)/sys/gamma_corr.sv $(ROOT)/sys/video_freezer.sv $(BUILD)/video/sync_fix.v $(ROOT)/sim/video_qualification.cpp >$(BUILD)/video/build.log 2>&1
	cd $(BUILD)/video && ./Vn8080_video
video-register:
	mkdir -p $(BUILD)/video-register
	$(VERILATOR) $(VFLAGS) --assert --threads 1 --x-initial unique --x-assign unique --top-module n8080_video_register --Mdir $(BUILD)/video-register $(ROOT)/rtl/n8080_video_register.sv $(ROOT)/sim/video_register_qualification.cpp >$(BUILD)/video-register/build.log 2>&1
	cd $(BUILD)/video-register && ./Vn8080_video_register
gamma-guard:
	mkdir -p $(BUILD)/gamma-guard
	$(VERILATOR) $(VFLAGS) --assert --x-initial unique --x-assign unique --top-module n8080_gamma_guard --Mdir $(BUILD)/gamma-guard $(ROOT)/rtl/n8080_gamma_guard.sv $(ROOT)/sim/gamma_guard_qualification.cpp >$(BUILD)/gamma-guard/build.log 2>&1
	cd $(BUILD)/gamma-guard && ./Vn8080_gamma_guard +verilator+rand+reset+1 +verilator+seed+1
hiscore:
	mkdir -p $(BUILD)/hiscore
	$(VERILATOR) $(VFLAGS) --top-module hiscore -GHS_ADDRESSWIDTH=16 -GHS_SCOREWIDTH=2 -GCFG_ADDRESSWIDTH=1 --Mdir $(BUILD)/hiscore $(ROOT)/rtl/vendor/hiscore/hiscore.v $(ROOT)/sim/hiscore_qualification.cpp >$(BUILD)/hiscore/build.log 2>&1
	cd $(BUILD)/hiscore && ./Vhiscore $(ROOT)/sim/results/mra/sheriff_hiscore.cfg
rotation:
	python3 $(ROOT)/tools/prepare_display_sim.py
	mkdir -p $(BUILD)/rotation
	$(VERILATOR) $(VFLAGS) -Wno-BLKANDNBLK --top-module n8080_rotation --Mdir $(BUILD)/rotation $(ROOT)/rtl/n8080_rotation.sv $(ROOT)/sim/results/display-platform.sv $(ROOT)/sim/rotation_qualification.cpp >$(BUILD)/rotation/build.log 2>&1
	cd $(BUILD)/rotation && ./Vn8080_rotation

scaling:
	mkdir -p $(BUILD)/scaling
	$(VERILATOR) $(VFLAGS) --top-module n8080_scaling --Mdir $(BUILD)/scaling $(ROOT)/rtl/n8080_scaling.sv $(ROOT)/sys/math.sv $(ROOT)/sim/scaling_qualification.cpp >$(BUILD)/scaling/build.log 2>&1
	cd $(BUILD)/scaling && ./Vn8080_scaling
flip:
	mkdir -p $(BUILD)/flip
	$(VERILATOR) $(VFLAGS) --top-module n8080_board --Mdir $(BUILD)/flip $(ROOT)/rtl/n8080_board.sv $(CPU_RTL) $(ROOT)/sim/flip_sound_stubs.sv $(ROOT)/sim/flip_qualification.cpp >$(BUILD)/flip/build.log 2>&1
	cd $(BUILD)/flip && ./Vn8080_board
