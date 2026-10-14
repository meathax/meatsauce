# Preflight repair and final boot check

The final fresh fast-tier run **passed all four 120-frame boots** (board/hostile, seeds1/2), with actual CLI exit0. Immutable run: `.preflight/runs/20261010-041137/`; tested source fingerprint: `01a92c0`; elapsed286s. Its generated hostile boot script contains `uio 0x32 0` before ROM loading. Video is256x224 at61.52Hz, pixel clock5.040MHz; all four outcomes agree.

This repair changes the installed Preflight tool. It preserves concurrent FPGA work, including the core gamma startup guard. It does not edit `sys/`, assemble an RBF, deploy hardware or qualify FPGA timing/utilization.

## Diagnostic window

The original bisection stopped at24 frames even though a normal Sheriff boot first produces a saved picture at24. It consequently blamed the driven `emu.pll_locked` wire without demonstrating a passing control. A provisional48-frame window then retained six initialized/driven signals: its saved late frames12/24 were black and36/47 showed pictures, so the majority classifier tied. The identical group passes a120-frame replay with actual simulator exit0. Neither attribution explains the full-window failure.

`src/preflight/diagnose.py` now preserves the observed `frames_after_boot` and configured `save_every`, and checks an all-zero control before attributing registers. Seven regression cases cover the measured artifact, original sampling, late failures and refusal to name a register when the control fails. Recovery patch: [`preflight_powerup_window.patch`](../tools/preflight_powerup_window.patch).

## HPS gamma initialization

The corrected full-window bisection isolated `emu.hps_io.gamma_en` (index535, one bit, `sys/hps_io.sv:253`) in20 runs. Enabling the gamma path while its lookup RAM is zero turns the rendered picture black. The tool's scratch-only initialization patch passed, but the project requires preserving `sys/`.

The virtual HPS boot generator omitted a defined gamma setting. `src/preflight/hps.py` now sends the default gamma-disabled command, `uio 0x32 0`, after video configuration and before ROM downloads. The [official MiSTer protocol](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/user_io.h#L57) defines this enable/disable command; the project decoder accepts it at `sys/hps_io.sv:528`. Three additional tests verify the payload, ordering for both ROM transports, video presets and reset status. All ten installed tool tests pass. Recovery patch: [`preflight_gamma_boot.patch`](../tools/preflight_gamma_boot.patch).

An earlier verification attached to an already-running job and passed without the new gamma command; it is separate evidence for the concurrent core guard. The final four-boot run above was started afresh and confirms that the corrected boot command is present. Its PASS covers the tested combined source image; it does not isolate the new HPS command from the independent guard.

## Evidence and limits

- Original failed run: `.preflight/runs/20261009-233350/`; invalid six-register attribution: `.preflight/runs/20261010-020031/`; full-window gamma finding: `.preflight/runs/20261010-024403/`.
- Scratch receipts/backups: `D:/vibes/fpga/temp/sheriff-preflight-baseline-20261010-013256/`, particularly `retained_group_check.json`, `group6-full-window/exit.json`, `full_window_fix.json` and `gamma_boot_fix.json`.
- Installed `diagnose.py` SHA256: `b6356e3bc7146785add5241e69d8d799687bc2d7b4a8513b693a3f9e0be22590`; `hps.py`: `e711854578687cfde064845f3c8b439fed6517a80251d05d0120a70156213fc9`.
- Final report retains an input-response risk and does not check place-and-route timing. The contact sheet visibly advances CREDIT00 to01; start/gameplay, complete graphics/audio and release qualification remain separate plan gates. No RBF was requested or built by this task.
