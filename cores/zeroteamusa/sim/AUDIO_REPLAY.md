# Production sound command replay

`audio_replay_main.cpp` runs the actual `ZeroTeam_audio` RTL: TV80, JTOPL2,
JT6295, plain staged sound ROM and the normal Seibu latch/interrupt circuit.
Its host supplies observed main-bus writes and physical coin pins, external
sample-ROM bytes, and output recording. It does not emulate a CPU or chip.
The main V30 is outside this component test; the complete AV runs remain the
acceptance path for CPU-driven gameplay and sound together.

Capture an original-ROM reference with the existing physical controller file:

```powershell
python scripts/capture_reference.py --frame 1800 --inputs sim/inputs/combat-2p.csv --label audio-pins --audio --sprite-buffer
```

Named captures are retained rather than overwritten. The SDL dummy device keeps
MAME synthesis active without playing on the host. `audio-stimulus.csv` records
main writes and changes of the **actual cached COIN port**. `set_value` changes
a requested field; MAME updates its digital port at the next input refresh.
Recording the request instead would advance every coin transition by one frame.
`timed-sound-events.csv` covers the full run independently of the older bounded
diagnostic trace.

Run Linux executables explicitly in Ubuntu WSL:

```powershell
wsl.exe -d Ubuntu --cd D:\Arcade\AI\aCORES\zero --exec bash sim/run_audio_replay.sh sim/results/mame-play-1800-combat-2p-audio-pins/audio-stimulus.csv sim/results/audio-replay-pins2p-complete 3150000000
```

Choose a fresh output directory for another case. The same compiled sound model
can run the four-player fixture without another build. The harness uses the
production board's four-byte register spacing (`cpu_addr[4:2]`), consumes all
events, checks enabled reset clocks and mono output, and records all chip writes.
Linux CSV parsing accepts Windows reference line endings.

The limit must exceed the final captured event, with time for the sound CPU to
respond. A 1,800-frame fixture has late commands just beyond 3,120,000,000
clocks; 3,150,000,000 leaves response time. The harness rejects a truncated
fixture before creating outputs or clocking the model. Retained 3,120,000,000
clock diagnostics exited 1 after consuming every in-window event; they are
not complete-fixture passes and do not need another long run merely to change
that exit status.

After completion, compare content and PCM measurements:

```powershell
python scripts/compare_audio_replay.py sim/results/mame-play-1800-combat-2p-audio-pins sim/results/audio-replay-pins2p
```

The comparison excludes timer/control register writes below `0x20` from the
musical stream and reports ADPCM commands separately. It checks reference
coverage and writes a private WAV. Exact raw write ordering is diagnostic:
timer phase and sound-driver voice allocation can change it. A mismatch must
be investigated, not treated automatically as a chip defect. MAME and JTOPL
waveforms are measured, not required to be bit-identical. Original-PCB timing
and final audible fidelity remain final hardware checks.

All ROMs, PCM/WAV files, native states and raw traces stay in ignored local
directories. Public evidence contains identities, counts and scoped results.
