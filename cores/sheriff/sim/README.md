# Simulation contract

Implementation is pending. Use Ubuntu WSL Verilator 5.032 and GHDL 5.0.1 already available on this machine. The top-level testbench must instantiate the same `n8080_board` RTL used by the MiSTer adapter.

Required output: native unrotated RGB frame files and hashes, event-timed bus/I/O/IRQ trace, selected RAM/state checkpoints, and audio PCM/WAV. Each run identifies ROM hashes, source revision, tool versions, input script, reset timing, frame/cycle counts and pass/fail.

The harness loads staged ROM images directly for simulation; it may shim PLL/HPS/DDR platform boundaries but cannot replace the CPU, renderer or sound-ROM execution. Use the same qualified T48 kernel with a pinned GHDL conversion if VHDL cannot be compiled directly by Verilator. Keep generated conversions reproducible.

First target: Sheriff boot and attract mode. Full milestone: scripted real gameplay covering the Phase 5 acceptance conditions in `plan.md`. Artifacts and full traces belong in ignored `verification/`; compact result manifests and source scripts belong in Git.
