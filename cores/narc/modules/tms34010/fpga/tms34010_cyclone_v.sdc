# TMS34010 Cyclone V timing contract.
#
# The two DE10-Nano oscillators are independent 50 MHz primary clocks.
# altera_pll owns every fabric clock; LCLK1/LCLK2 are output waveforms and
# never clock FPGA state. External-interface delay values include the board
# trace and mandatory level-translator budget; the companion timing notes
# state the protocol-level setup/hold and wait-state requirements.

# ---------------------------------------------------------------------------
# Primary, generated, and virtual interface clocks
# ---------------------------------------------------------------------------

create_clock -name FPGA_CLK1_50 -period 20.000 \
    [get_ports {FPGA_CLK1_50}]
create_clock -name FPGA_CLK2_50 -period 20.000 \
    [get_ports {FPGA_CLK2_50}]

derive_pll_clocks

set core_clk [get_clocks \
    {u_clock_pll|u_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set bus_clk [get_clocks \
    {u_clock_pll|u_pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set video_clks [get_clocks \
    {u_video_pll|u_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
     u_video_pll|u_pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set video_core_clk [get_clocks \
    {u_video_pll|u_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set video_pin_clk [get_clocks \
    {u_video_pll|u_pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

# Virtual clocks describe external protocol timing without pretending that an
# unrelated external controller clocks FPGA state.
create_clock -name HOST_EXT  -period 100.000
create_clock -name ASYNC_EXT -period 100.000

# The core/bus bridge and every core/video exchange are explicit two-phase
# MCP mailboxes. Source payload registers remain stable through synchronized
# request/acknowledge toggles; the clocks therefore have no timing phase
# relationship even though core and bus happen to share one PLL on this board.
set_clock_groups -asynchronous \
    -group $core_clk \
    -group $bus_clk \
    -group $video_clks

# The CPU's own exceptions (multicycle and false paths inside tms34010_core) live in
# tms34010_core.sdc next to this file, so game cores can read the same file.
source [file join [file dirname [info script]] tms34010_core.sdc]

# ---------------------------------------------------------------------------
# Asynchronous reset, interrupt, host, and external-sync inputs
# ---------------------------------------------------------------------------

set async_control_inputs [get_ports \
    {RESET_N RUN_EMU_N HCS_N HREAD_N HWRITE_N HLDS_N HUDS_N \
     HFS[*] HD[*] LINT1_N LINT2_N HSYNC_N VSYNC_N}]

# The reset conditioners guarantee asynchronous assertion and synchronous
# two-register release independently in core, bus, and video domains.
# Interrupts, external syncs, and the host access level likewise enter only
# through attributed 2FF synchronizers. Host HFS/HD/direction/byte enables
# are a bundled payload held from before access assertion until HRDY release.
# Cut only paths ending in fabric registers so the direct host pin response
# paths below remain bounded.
set_false_path -from $async_control_inputs -to [get_registers {*}]

set_input_delay -clock HOST_EXT -max 10.000 \
    [get_ports {HCS_N HREAD_N HWRITE_N HLDS_N HUDS_N HFS[*] HD[*]}]
set_input_delay -clock HOST_EXT -min 0.000 \
    [get_ports {HCS_N HREAD_N HWRITE_N HLDS_N HUDS_N HFS[*] HD[*]}]
set_input_delay -clock ASYNC_EXT -max 10.000 \
    [get_ports {RESET_N RUN_EMU_N LINT1_N LINT2_N HSYNC_N VSYNC_N}]
set_input_delay -clock ASYNC_EXT -min 0.000 \
    [get_ports {RESET_N RUN_EMU_N LINT1_N LINT2_N HSYNC_N VSYNC_N}]

# HRDY is the immediate asynchronous wait response. The 30 ns bound leaves
# 10 ns of the SPVS002C 40 ns maximum for translation and board uncertainty.
# Host read data uses 70 ns of the specified 90 ns no-wait access budget.
# The host has no clock relationship with the core, so register-to-pin paths
# use explicit absolute delays instead of a fictitious synchronous output
# relationship to HOST_EXT.
set_max_delay 30.000 -from [get_ports \
    {HCS_N HREAD_N HWRITE_N HLDS_N HUDS_N HFS[*]}] \
    -to [get_ports {HRDY}]
set_max_delay 70.000 -from [get_ports \
    {HCS_N HREAD_N HWRITE_N HLDS_N HUDS_N HFS[*]}] \
    -to [get_ports {HD[*]}]
set_max_delay 70.000 -from [get_ports {*}] \
    -to [get_ports {HRDY HINT_N HD[*]}]
set_min_delay 0.000 -from [get_ports {*}] \
    -to [get_ports {HRDY HINT_N HD[*]}]
set_max_delay 20.000 -from [get_registers {*}] \
    -to [get_ports {HRDY HINT_N HD[*]}]
set_min_delay 0.000 -from [get_registers {*}] \
    -to [get_ports {HRDY HINT_N HD[*]}]

# ---------------------------------------------------------------------------
# Source-synchronous local-memory and video pins
# ---------------------------------------------------------------------------

# HOLD/LRDY/LAD are sampled only on documented 8x subphases and the external
# devices guarantee their protocol setup/hold at those edges. Absolute 10 ns
# max / 0 ns min constraints bound the FPGA pin-to-register portion without
# falsely requiring the data to be launched on every 200 MHz edge.
set local_input_ports [get_ports {HOLD_N LRDY LAD[*]}]
set_max_delay 10.000 -from $local_input_ports -to [get_registers {*}]
set_min_delay 0.000 -from $local_input_ports -to [get_registers {*}]

# Local outputs are functions of a command held for a complete two-period bus
# cycle and an 8x phase counter. The 20 ns absolute limit covers command and
# phase decode to a pin before its protocol sampling phase, including the
# intentionally slow 3.3-V header edge setting.
set local_output_ports [get_ports \
    {HLDA_EMUA_N LCLK1 LCLK2 LAD[*] RAS_N LAL_N CAS_N WE_N \
     TR_QE_N DEN_N DDOUT}]
set_max_delay 20.000 -from [get_registers {*}] \
    -to $local_output_ports
set_min_delay 0.000 -from [get_registers {*}] \
    -to $local_output_ports

# VIDEO_VCLK is the PLL's physical 180-degree forwarded clock. Sync/blank
# outputs launch on the internal VCLK edge, coincident with VIDEO_VCLK
# falling. The absolute 20 ns FPGA path bound reserves 10 ns of the specified
# 30 ns response for translation and board delay. The forwarded clock is
# itself constrained by the derived PLL clock; it is not a data endpoint.
set_max_delay 20.000 -from [get_registers {*|u_video_subsystem|*}] \
    -to [get_ports {HSYNC_N VSYNC_N BLANK}]
set_min_delay 0.000 -from [get_registers {*|u_video_subsystem|*}] \
    -to [get_ports {HSYNC_N VSYNC_N BLANK}]
set_false_path -to [get_ports {VIDEO_VCLK}]

derive_clock_uncertainty
