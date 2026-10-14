# Live physical cabinet inputs in Verilator

New original-ROM boot models poll a private command mailbox while continuing natural execution. This changes only the four cabinet input pin groups. It does not restore RAM, set CPU state, skip instructions, advance timers or manufacture interrupts. Coin edges and all game responses pass through the real RTL board I/O, GPIO and interrupt controller.

The model's startup line prints the mailbox path; `scripts/sim.py` captures that output until the model returns, so read `sim/obj_dir/boot_probe/activity/latest_run.json` to discover the live run. By default its mailbox is `sim/obj_dir/boot_probe/activity/<run_id>/cabinet_commands.txt`. The optional fourth extra boot argument selects a different command input path; the history remains in that run's private directory. Each command overwrites the mailbox with one newline-terminated line:

```text
sequence hold_frames p1_p2_n p3_p4_n system_n dips_n
```

Sequence and frame duration are unsigned decimal. Pin values are unsigned hexadecimal without `0x`; player groups have 32 bits, system/DIP groups eight. Sequence must increase. Missing, unfinished, oversized, invalid or stale commands do not change pins. Polling is bounded to once per 500,000 system clocks; an active duration expires at the actual raster-frame boundary. Nonzero duration automatically releases both player groups and system pins after that many vblanks. Zero duration holds them until the next command. DIP pins retain their last value after release.

Examples with normal DIPs:

```text
1 2 ffffffff ffffffff ef ff
2 12 ffffffff ffffffff fe ff
3 2 ffffffff ffffffff df ff
4 12 ffffffff ffffffff fd ff
5 60 ffbffffe ffffffff ff ff
```

These respectively insert P1 coin, press P1 start, insert P2 coin, press P2 start, and hold P1 right + button 1. Submit each after the previous command has actually applied/released and after the game reaches the intended state. The examples are not a pre-timed attract/gameplay acceptance script.

The pinned `crystal.cpp` input map is authoritative:

| Active-low pin bit | Function |
|---|---|
| `system_n` 01 / 02 | P1 / P2 start |
| `system_n` 10 / 20 | P1 / P2 coin |
| `system_n` 40 / 80 | Service credit / service menu |
| `p1_p2_n` 00000001 / 00000002 | P1 / P2 button 1 |
| `p1_p2_n` 00000004 / 00000008 | P1 / P2 button 2 |
| `p1_p2_n` 00000010 / 00000020 | P1 / P2 button 3 |
| `p1_p2_n` 00000040 / 00000080 | P1 / P2 button 4 |
| `p1_p2_n` 00010000 / 00020000 | P1 / P2 up |
| `p1_p2_n` 00040000 / 00080000 | P1 / P2 down |
| `p1_p2_n` 00100000 / 00200000 | P1 / P2 left |
| `p1_p2_n` 00400000 / 00800000 | P1 / P2 right |
| `dips_n` 01 / 02 / 80 | Pause / free play / test (low activates) |

`cabinet_inputs.csv` records the actual application/release clock, raster frame, sequence and all four pin groups. Boot metadata records command/release counters and the actual pin state. Terminal analysis checks event counts, order, widths and file hash. No command file means the existing released-input boot behavior continues unchanged.

The host-only driver check passes 21 checks covering duration/release, persistent DIPs, stale commands, invalid widths/signs/extra tokens and an unfinished but otherwise parseable write. Original-game credit, start, sound and P1/P2 responses still require verification in the running original-ROM model. This driver is stimulus, not an emulated game or an acceptance shortcut.
