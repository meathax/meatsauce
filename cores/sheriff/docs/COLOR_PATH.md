# Corrected isolated color circuit

Connected related-Bandido sheets33/34 support this model. It remains outside `files.qip` and the production board. The initial O2/O3 swap and NAND-to-red-A interpretation are withdrawn. Original sources/report are in `_checks/agent-color-control-20261010/superseded-assumption/`; original native receipts remain in `_checks/agent-color-20261010/native/`. Passing assertions on that assumed model did not qualify its incorrect source claims.

3L O1/O2/O3 reach3K D4/D1/D3. NAND(O4,mode2_n) feeds3K D2; the held nQ2 is O4 AND mode2_n. Three complemented color outputs drive mux B; OUT6 Q0/Q1/Q2 drive mux A directly. The decoder/gates give S=mode0 OR ((mode1 OR mode2) AND held_nQ2), ST=mode3. See [the connected control trace](COLOR_CONTROL_TRACE.md).

The [TI LS158 table](https://www.ti.com/lit/ds/symlink/sn74ls158.pdf) gives inverted selected data and high outputs when ST is high. Common4D NAND video gating drives ideal PNP conduction. `pnp_on` models that condition; CRT analog polarity, amplitude and settling remain unqualified.

The corrected focused test checks64 captures,256 live-mode changes without capture,64 static MAME color matches and256 video blanks. The held selector can temporarily differ from MAME's instantaneous mode change; no phase shift follows. MAME dump bits0/1/2/3 associate functionally with O1/O2/O3/O4 in the static comparison, not an independently proven programmer pin-order bridge.

Remaining gates: exact Sheriff revision, tied-high CLR/power-up, ROM/address/capture ordering and propagation, CRT analog polarity and physical RAM/visible origin. Field2760 and whole graphics remain open. Existing capture CE and physical primitives are unchanged.
