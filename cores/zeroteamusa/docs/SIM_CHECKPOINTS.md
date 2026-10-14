# Native live-board diagnostic checkpoints

`sim/run_av.sh` builds the actual production CPU/COP/video/cipher/sound RTL
with Verilator `--savable`. This is separate from MiSTer OSD savestates.
Use Ubuntu WSL for both builds and execution; never run the Linux ELF
directly from PowerShell.

At each default 104,000,000-cycle boundary, the harness saves three local
files under ignored `sim/results/`:

- `.rtl`: the native Verilator model, including all real registers, memories,
  CPU pipelines, COP/chip state and module input/output latches.
- `.host`: all pending external ROM requests, due cycles, acknowledge tokens,
  address/kind, edge-detection state, images and diagnostic counters.
- `.json`: the actual build-input/ROM hashes, Verilator version and model mode.

The saved cycle is the **next** cycle to execute after a completed system
clock. A restore resumes through the same clocked production RTL. It does
not replace the CPU, set credits, load MAME memory or bypass protection.
Streams contain private game data and must remain ignored/local.
Each process freezes its own build inventory at startup so another local
run cannot change the provenance of a later checkpoint. Resume-parent
stream hashes and physical-input hashes are recorded when present.

Example from PowerShell, with the workspace as current directory:

```powershell
wsl.exe -d Ubuntu --cd D:\Arcade\AI\aCORES\zero --exec bash ./sim/run_av.sh 1040000000 --load sim/results/av-checkpoint-104000000
```

The cycle limit is absolute since cold reset, not an additional duration.
Use `--inputs sim/inputs/play-2p.csv` to replay physical inputs. For a 4P
cabinet fixture, apply its input CSV from cold reset so cabinet selection
is present when the program initializes. See `docs/INPUTS.md`.
`--tag example` separates final outputs/checkpoint names. `--checkpoint-every`
sets a cycle period; zero disables saves.

The launcher rejects restoration when RTL, ROM, model options or Verilator
version differ. If production hardware changes, cold boot the changed
model; do not force an incompatible serialization into it.

The focused round-trip check saved at cycle 100,000 and continued through
200,000. Uninterrupted/restored counters, seven RAM ranges and final images
are exactly equal; `docs/evidence/av-checkpoint-roundtrip.json` records the
build inputs and scope. Later real attract/gameplay continuation remains a
separate validation gate; this early test is not broad gameplay proof.
