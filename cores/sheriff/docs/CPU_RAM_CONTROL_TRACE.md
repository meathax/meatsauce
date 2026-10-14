# CPU RAM control source trace

The raw source and equation for `CPU_WR_RD` remain unresolved. This investigation changes no production RTL and qualifies no RAM arbitration behavior.

The staged related Bandido CPU schematic, sheet 35, shows the following connected pins:

- CPU-board `3E` LS02 output pin 1 points upward into `5B` LS32 input pin 9.
- The lower tied-input `3E` gate output pin 4 feeds upper `3E` input pin 3.
- The lower gate inputs 5 and 6 are tied together.

The decisive retained view is `_checks/agent-cpu-ram-control-20261010/cpu-3e-connected.png`, original page-35 pixel box `[2980,3480,3260,4370]`. Gate orientation matters: output 1 is above the gate symbol; the lower ends are inputs 2 and 3.

`CPU_WR_RD` turns near original coordinates `(3555,5210)`. The source continuation around rows 4215 and 4250 includes closely aligned risers with gaps and separate bends. The retained `cpu-lower-joins.png` box `[2990,4120,3750,4420]`, `cpu-wrrd-origin.png` box `[3400,5080,3800,5260]` and `cpu-input-control-connected.png` box `[2080,3350,3750,5500]` make that ambiguity reviewable. These observations do not establish which raw CPU signal drives each gate input.

Before RAM arbitration can be implemented, trace those continuations back to actual DBIN/WR pins and join the CPU `CPU_WR_RD` signal to the video-board RAM input with its polarity intact. The exact Sheriff revision and propagation/capture ordering also remain open. A truth-table test of an assumed equation would not resolve these source questions.

Original PDF/render and viewport hashes, coordinates and source generator recovery paths are retained in `docs/evidence/sheriff_cpu_ram_control_trace.json`. This source-only report does not claim a native or hardware pass.
