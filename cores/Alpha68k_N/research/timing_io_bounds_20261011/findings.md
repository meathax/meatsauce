# External I/O constraint findings — 2026-10-11

The original complete sound-ROM-reader fitted image has exactly 20 unconstrained input ports and 85 unconstrained output ports. All thirteen reported clocks are constrained. This report classifies every reported endpoint; it does not claim electrical timing closure. The source hashes and exact report excerpt are retained beside this document. No RTL, SDC, QSF, pinned framework or system configuration was changed; no compile, replay, RBF or hardware test was launched.

| Interface | Input count | Output count | Required treatment |
|---|---:|---:|---|
| SDRAM | 16 | 35 | Related forwarded clock and device/module-derived min/max delays |
| HDMI video | 0 | 28 | Two possible forwarded-clock modes, actual DDIO inversion, receiver min/max delays |
| HDMI audio | 0 | 4 | Serializer cadence and source synchronous I2S/LRCLK budget; MCLK clock role |
| HDMI HPS I2C | 1 | 2 | HPS hard-block boundary and external I2C electrical/protocol qualification |
| HDMI interrupt | 1 | 0 | Asynchronous HPS status boundary, exact sink review |
| MCP I2C | 1 | 2 | Related protocol arrival/sample timing and open-drain electrical budget |
| Card detect/SPDIF | 1 | 1 | Distinct asynchronous input and serial audio output functions |
| LEDs | 0 | 3 | Human indicators; precise output exceptions are legitimate after sink inventory |
| Analog video/SD mux | 0 | 6 | Analog output profile and constant/tri-state core SD paths |
| Analog sync/SD-CS mux | 0 | 1 | Analog sync output profile and constant/tri-state core SD paths |
| USER optional I2S | 0 | 3 | Optional external audio receiver budget, not an unused port blanket |

## SDRAM

Reuse the existing canonical `research/quartus_sdram_constraint_spec.md/.json`. The controller is AW22/HF0/SHIFTED0, CL2, burst1; commands, write DQ and read capture use the 48MHz master. The related second PLL output forwards 48MHz at requested 10416ps phase. This is one game master with enables, not permission to change the frequency or insert an independent game clock. The report's 35 dynamic outputs comprise A[12:0], DQ[15:0], DQM[1:0], nCAS/nRAS/nWE and CLK. BA/nCS/CKE are absent from this UCP table; their actual fitted constant/exception status still belongs in the complete endpoint census.

The indispensable unresolved facts are the installed module revision, exact SDRAM part and speed suffix, operating voltage/temperature/load profile, and FPGA-pad-to-SDRAM-clock/data/control minimum/maximum flight bounds. Capacity flags cannot supply these facts. Use datasheet read tAC/hold/active-drive boundaries and setup/hold values. No zero-delay placeholder, borrowed other-core numeric profile, CL2 multicycle or blanket SDRAM false path is justified.

## HDMI video and audio

`sys/sys_top.v:1262–1297` selects scaler HDMI clock or direct-video clock and forwards a clock through DDIO with datain_h=0/datain_l=1. Output video registers launch on the selected clock's rising edge (`1304–1337`). The external forwarded waveform is therefore inverted relative to that internal launch; representing the inversion and both master alternatives is necessary. Preserve actual propagated clock latency and review the fitted waveform rather than guessing a PLL hierarchy. The 27 video data/control outputs require min/max constraints against the appropriate HDMI_TX_CLK generated clock(s); the clock output needs a reviewed clock endpoint treatment.

[ADV7513 Rev B](https://www.analog.com/media/en/technical-documentation/data-sheets/adv7513.pdf), pp3–4, gives video setup 1.8ns and hold 1.3ns, plus I2S/LRCLK setup and hold 2ns each. These are receiver requirements; output delay also needs actual PCB data-versus-clock skew. The selected ADV7513 input-clock adjustment is relevant because the device has programmable clock/data relationship. Target DE10-Nano revision and supported maximum HDMI pixel-clock profile must be identified; the official [Terasic resources](https://www.terasic.com.cn/cgi-bin/page/archive.pl?CategoryNo=205&Language=English&No=1046&PartNo=4) provide separate revisions. A historical other-core pad budget cannot automatically qualify this image.

`sys/i2s.v:19–51` updates serial data/LRCLK under ce and delays SCLK by one audio-master tick through msclk. The finite qualification should derive the shortest valid data-to-SCLK setup/hold intervals from the actual supported 48/96kHz cadence and rate transitions, then combine fitted pad arrivals with ADV7513 requirements and PCB skew. Do not impose an invented 20ns absolute-arrival allowance that charges common clock latency twice (indexed lesson at lessons.md:6457). HDMI_MCLK is forwarded clk_audio (`sys_top.v:1569`); whether it is enabled/required by the actual ADV7513 configuration must be documented. USER_IO[2,4,5] mirror I2S/SCLK/LRCLK when SW[1] is set even though core USER_OUT is 7'h7f. A supported user-port receiver needs a receiver/cable profile; otherwise clearly delimit that optional mode instead of declaring these ports unused. SDCD_SPDIF output serial SPDIF similarly needs its actual configured analog-board sink/profile.

## Low-rate boundaries

HDMI_I2C_SDA/SCL connect to the Cyclone V HPS I2C hard block (`sys_top.v:1129–1139`), not a game-domain sampler. The source's 10MHz hdmi_sck STA surrogate does not identify Linux's actual SCL rate or qualify pull-up rise/fall and ADV7513 400kHz limit. Separate the fabric hard-block boundary classification from physical I2C protocol qualification. Do not falsely claim ordinary 10MHz synchronous I2C transfers are required.

IO_SDA is read directly into ACK/rdata by FPGA_CLK2_50 registers at detected I2C-clock edges (`sys/i2c.v:82–98`); it is actual read data, not an arbitrary asynchronous user switch. `mcp23009.sv:27` requests 500kHz. Its accumulator toggles each 1us at 50MHz, giving nominal 1us low time. [Microchip DS22121A](https://ww1.microchip.com/downloads/en/DeviceDoc/22121a.pdf), pp35–36, guarantees fast-mode low time at least 1.3us and output-valid delay up to 0.9us under its stated conditions. Thus the source alone does not qualify this 500kHz profile against the fast-mode electrical envelope. High-speed-mode values must not silently be substituted. Preserve the pinned framework; record this framework interface limitation and decide a qualified supported profile centrally. No I2C-wide false path may conceal insufficient SDA sampling margin.

HDMI_TX_INT feeds HPS gp_in at `sys_top.v:234,281–285`; its status changes asynchronously. A narrowly named exception to the reviewed hard-block endpoint is conceptually legitimate, but must bind actual fitted sinks and HPS status semantics. SDCD_SPDIF input is card detect, feeding selection of unused core SD_MISO/SD_CD (`sys_top.v:131–137`, core SD outputs constant at `Alpha68k_N.sv:275`). Confirm fitted cone/sinks; do not waive its independent SPDIF output.

LED[0,2,6] are human indicators, with no external synchronous receiver. SDIO_CLK/CMD/DAT[3:0] and SD_SPI_CS are muxed analog VGA/color/sync versus constant or tri-stated core SD outputs. They should be declared against an explicit analog profile with precise endpoint output exceptions where no clocked receiver exists; the root-to-pad transition/bandwidth requirements can be checked separately if required. Broad USER*, HDMI*, SDRAM* or all-port exceptions are unjustified. Internal game/CDC/reset closure is independently owned by timing_crossings and remains a separate failing gate.

## Smallest next qualification

1. Keep current HDL/48MHz game clock fixed; obtain the exact module/part and target DE10-Nano/I/O-board revisions, supported HDMI modes and optional user/SPDIF sink scope.
2. Construct one source-bound board I/O profile: SDRAM part limits and flight bounds; HDMI board skew/receiver mode; supported audio cadence and applicable external receiver/cable bounds; HPS I2C actual rate/pull-ups. Use official schematics/layout or measured conservative bounds rather than requesting arbitrary experiments.
3. Add reviewed core-owned constraints after the pinned framework SDC, with checked nonempty/exact clock/port collections. Preserve related master/SDRAM paths, HDMI forwarded inversion and multiple modes. Classify each low-rate endpoint by actual sinks, not wildcards. Reuse the existing routed DB for diagnostic STA; refit once the legitimate constraint profile is settled.
4. Require numeric input/output setup/hold and clock checks in every corner, all dynamic/constant/async endpoint classifications, zero unexplained unconstrained paths, and independent game/CDC closure. A resource pass or functional Verilator SDRAM transfer does not close this electrical gate.

Scope limit: this investigation deliberately does not identify the installed physical memory part, derive PCB trace geometry from an unknown board revision, change the pinned framework or claim a hardware pass.
