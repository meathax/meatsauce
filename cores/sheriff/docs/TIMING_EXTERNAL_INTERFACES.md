# Sheriff external interface timing audit

This audit retains the framework unchanged. It identifies supported receiver
requirements and remaining electrical/mode evidence; it does not manufacture
output delays, approve all inherited exceptions, or qualify a failed fit.

## HDMI video and audio

The [ADV7513 Rev. B data sheet](https://www.analog.com/media/en/technical-documentation/data-sheets/adv7513.pdf),
Table 1, printed pages 3-4, requires video input setup 1.8 ns and hold 1.3 ns.
I2S data and LRCLK require 2 ns setup and hold. Video clock/data relationship
is programmable in 400 ps steps. These are receiver-pin requirements; earlier
hardware-guide figures of 1.0/0.7 ns are not the Rev. B video specification.

Unchanged sys/sys_top.v:1274-1299 forwards inverted hdmi_tx_clk using altddio_out
(high data 0, low data 1); :1304-1337 registers RGB/HS/VS/DE on its rising edge.
Consequently the default forwarded rising capture edge is approximately a half
cycle after the data launch. At the retained 148.5 MHz scaler clock, the ideal
half-cycle is 3.367 ns: before FPGA clock/data skew, PCB skew, uncertainty and
programmed receiver delay, the ideal setup remainder is 1.567 ns and hold
remainder is 2.067 ns. Those remainders are budgets, not measured slack.
Direct-video clock selection and the actual ADV7513 programmed delay must be
bound separately; no borrowed 0.5 ns PCB skew is asserted as measured here.

The framework I2S serializer changes data/LRCLK when msclk is high; its sclk
register follows msclk one audio-clock edge later. The audio_out cadence is
6.144/12.288 MHz mclk_ce, divided by two for i2s_ce, yielding 48/96 kHz stereo
16-bit framing and at least four parent clocks between nominal SCLK transitions
in the fastest stable mode. Pin delays, rate/reset transition behavior, actual
clock frequency and selected output electrical modes still require measurement.
An arbitrary absolute pad-delay bound would incorrectly spend shared clock
latency and does not establish receiver setup/hold.

## MCP23009 expander

The [Microchip DS20002121C data sheet](https://ww1.microchip.com/downloads/aemDocuments/documents/OTH/ProductDocuments/DataSheets/20002121C.pdf),
Table 2-4, printed pages 35-36, defines 100/400 kHz and 3.4 MHz timing modes.
At 400 kHz, SCL high/low minima are 0.6/1.3 us, data setup is 100 ns, and output
valid from clock is at most 0.9 us. High-speed-mode figures are conditional on
2.7-5.5 V and their specified loading. Pullup/load and actual mode matter.

Unchanged sys/mcp23009.sv:27 requests 500000 Hz from the 50 MHz i2c module.
The accumulator toggles its I2C_CLOCK every 50 fabric clocks, producing nominal
1 us high and low phases. Its ACK/data sample executes one fabric clock after
the internal rising transition; SDA changes after an internally falling
transition and a four-register output delay. Thus the 400 kHz-mode 1.3 us low
minimum is not established by that cadence. This is a conditional platform
qualification gap, not a confirmed Sheriff hardware defect: the actual device,
voltage, high-speed-mode applicability, electrical pullups/load and pin waveform
have not been bound. No sys/ edit or I2C false path is proposed.

## Inherited CDC and status exceptions

sys/sys_top.sdc:13-22 cuts clock-domain interactions using -exclusive. Official
[Quartus 17 clock-group documentation](https://resources.altera.com/quartushelp/17.0/analyze/sta/sta_db_set_clock_groups.htm)
identifies exclusive clocks as inactive simultaneously and asynchronous clocks
as unrelated; both cut inter-group timing. Game, audio and framework clocks
operate concurrently here. The inherited word exclusive therefore does not
prove physical exclusivity or CDC safety. Proper crossings, mode stability and
exception scope must be reviewed independently; changing the spelling alone
would not provide that evidence.

Human status outputs have no clocked receiver; their existing status-role
classification supports a status exception. Analog/encoded/shared-mode ports
require their real interface contract. No GPIO-wide or external-interface-wide
false path is supported. The existing 114 external rows remain source-classified
as documented in PLATFORM_IO_REVIEW.md; this audit adds numeric receiver
requirements without claiming complete external-interface closure.

Exact unchanged source excerpts and hashes are retained in
D:/Arcade/AI/aCORES/sherrif/_checks/timing-trial-observation-20261010/
external-source-excerpts.json, external-source-excerpts-2.json and
audio-cadence-source.json. The retained SEED2 trial ended with actual fitter
exit -1 at 2026-10-10T05:41:25Z, without finalization; its copied successful
summary predates the trial and is not usable acceptance evidence.
