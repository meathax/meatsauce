# Alpha68k N — SDRAM timing constraint specification

This is a read-only specification. No Quartus run, SDC change or electrical timing pass is claimed.

The physical PLL produces related 48 MHz clocks at 0 ps and 10416 ps. The second clock drives SDRAM_CLK. The controller captures read DQ and registers commands/address/write DQ on the first clock’s rising edge (jtframe_sdram64.v:189–221). Its falling-edge logic at lines179–183 changes reset qualifiers; it does not capture read DQ. The actual parameters are AW22/HF0/SHIFTED0, CL2 and burst 1. These facts do not identify an SDRAM part or speed grade.

The core SDC only derives clocks and uncertainty. The minimum correction scope is a verified forwarded clock reference at SDRAM_CLK and explicit maximum/minimum external delays for read DQ and address/control/write DQ/DQM outputs. Preserve the related PLL phase and ordinary opposite-edge paths. Do not add blanket false paths or a CL2-based multicycle.

Use FPGA SDRAM_CLK pad as the reference. Read maximum arrival is clock-flight(max) + device tAC(max) + read-data-flight(max). The minimum must account for the selected device’s guaranteed hold and finite active-drive/release boundary. Output maximum is device tSU + data-flight(max) - clock-flight(min); output minimum is data-flight(min) - clock-flight(max) - device tH. These are symbolic derivations; every board/device parameter is currently unresolved. Do not substitute zero or values from another core.

The exact SDRAM module/part/speed grade, voltage/temperature/load conditions, clock/data trace bounds and fitted PLL/output-register details are needed before numerical constraints can be qualified. The JSON records source lines, hashes, unresolved parameters and command shapes.

After baseline fit, check real generated-clock/port collections, I/O register placement and unexplained SDRAM endpoints. Final checks must cover input/output setup and hold, ordinary opposite-edge paths, recovery/removal and pulse widths across required corners. The current simulation proves functional transfers; it does not supply those electrical bounds.

Quartus 17 requires explicit minimum and maximum input delays for separate hold/setup analysis: [official input-delay documentation](https://resources.altera.com/quartushelp/17.0/analyze/sta/sta_db_set_input_delay.htm).

The framework’s PLL clock-group wildcard uses a pll|pll_inst hierarchy. The custom core PLL uses a different instance hierarchy. Verify the actual fitted wildcard matches; template names alone do not prove which clocks were grouped.
