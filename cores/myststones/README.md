# Mysterious Stones — recovered MiSTer source

This folder preserves the recovered game-specific FPGA source and Quartus configuration for Mysterious Stones.

**This is a partial source snapshot. It is not a complete, standalone buildable project.** No compilation or hardware validation is claimed for this recovery.

## Provenance

The files were recovered from [VIDEOGEN's source evidence](https://github.com/meathax/VIDEOGEN/tree/b9b443312feae38fa11991c27d9d2f7bdb6da8cf/MYSTERIOUS_STONES/evidence/source) at commit `b9b443312feae38fa11991c27d9d2f7bdb6da8cf`. That repository is private, so its links require access.

The [source audit](https://github.com/meathax/VIDEOGEN/blob/b9b443312feae38fa11991c27d9d2f7bdb6da8cf/MYSTERIOUS_STONES/evidence/source-audit.json), dated 14 October 2026, records the original project directory as `D:\Arcade\AI\aCORES\stones`. The snapshot was first committed in [3e8a77b4](https://github.com/meathax/VIDEOGEN/commit/3e8a77b4d8333c4a3f011cc11ae48b1d2e76dacf).

Original relative filenames have been restored here. All five files retain their exact recorded bytes, line endings, comments, and attribution. Their SHA-256 hashes match the audit.

| Recovered path | Evidence filename | SHA-256 |
|---|---|---|
| `rtl/stones_board.sv` | `board.sv` | `f42615d817f95f4321a531a5cb74f3c5db1d1da736e3ae41ceea2d5e5b4dc3f4` |
| `rtl/stones_video.sv` | `video.sv` | `9194988867fecf7b6be47de2a2a5b7ef8bc6367431199b8d8f13104a1fc47de0` |
| `rtl/stones_game.sv` | `game.sv` | `e83a8931a68ba7d071598990fdaf432e6196fa88897fa41a08584d8633c41e22` |
| `Arcade-MysteriousStones.qsf` | `build.qsf` | `c551ca80607f7b89c13bdc5302cc3b7454c5377da2cec16df5c4167504029488` |
| `files.qip` | `files.qip` | `b9c70826bcb7317096b97fcf1ba2d559e9f66e4fbd4fefa043554cda5e7c11e7` |

The original evidence remains in VIDEOGEN. Its `mystston.cpp` and `ddragon.cpp` files are MAME research references and are not part of this FPGA build.

## Files still needed for a complete project

The preserved `files.qip` and Quartus configuration refer to files that were not present in the recovered snapshot:

- `Arcade-MysteriousStones.sv` — MiSTer wrapper.
- `Arcade-MysteriousStones.sdc` — timing constraints.
- `sys/` — MiSTer framework, including `sys.tcl` and `sys_analog.tcl`.
- `rtl/vendor/` — T65, JT49, CRT adjustment, and hiscore dependencies.
- `credits/credits.qip` and its supporting files.

The original `Arcade-MysteriousStones.qpf` project file was also absent from the snapshot. Recover the missing project files and their applicable attribution before attempting a full build.
