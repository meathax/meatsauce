# Kyros long combat and death replay evidence

Parent f6dbcd3. These are completed real CPU runs using recorded legal ports,
without game RAM patches. Source/ELF/ROM/input hashes and revisions are in
the terminal receipts. Counts qualify these finite executions only.

- kyros_idle_death3601: 3601 fields; all metric checks pass, worst line 2280 master ticks. 19 canonical images match exactly; differing pixels by field: [(900, 4)]; missing RTL checkpoints: [119, 179, 1799]. All comparisons remain in research/kyros_idle_death3601_verification.json.
- kyros_combat3600_native: 3600 fields; all metric checks pass, worst line 2280 master ticks. 56 canonical images match exactly; differing pixels by field: [(60, 20835), (900, 8), (1020, 8), (2100, 8), (2220, 12), (3180, 4), (3300, 8)]; missing RTL checkpoints: [119, 179, 1799]. All comparisons remain in research/kyros_combat3600_native_verification.json.

Every field contains 57,344 unique pixels; unmapped accesses, duplicate pixels,
renderer deadline misses and overflow counts are zero. Missing images119/179/1799
are absent from the original RTL capture schedule, not evidence of differing
pixels. Capture availability is reported separately from execution metrics.
No complete graphics gate is closed; no masks, frame shifts or clock changes
were used. The small combat differences need timed-write diagnosis alongside
B16; field60 is the measured mid-field backdrop transition already documented
in RASTER_TIMING_DIAGNOSIS.md.

Ordered sound chip/latch writes match throughout death3601; DAC was not captured
in that run. Combat has157 matching main latch writes and42,246 matching
ordered DAC writes (one field-label difference). Its22,418 chip-I/O writes
have a real ordered-stream comparison failure, beginning at index896, field787:
MAME address16/data1 versus RTL address145/data6. Equal total counts do not
qualify the sequence. Preserve and diagnose this difference before closing
B03/B04 audio coverage. No PCM, all-effects or physical audio pass is implied.

Only unlabelled final RTL sprite/work RAM dumps exist in these binaries;
no checkpoint RAM equivalence or scored/death state equivalence is inferred
from those dumps. Matching canonical checkpoint images support only the
displayed states actually sampled.

Next: inspect the first combat sound divergence and timed sprite writes for
the failed images, implement only an evidence-supported correction, then
capture the missing nonperiodic checkpoints in the next necessary native run.
Do not rerun both long jobs merely to repeat passing metrics.


## Sound interleaving diagnosis

Parent60018db. MAME0.289 sound_iomap identifies separate YM2203, AY1 and AY2
port pairs; the exact source SHA and map are saved in
research/kyros_combat3600_sound_interleaving.json. Projection onto each chip
preserves every accepted write and confirms identical ordered port and decoded
register/data streams: YM2203=10,404; AY1=3,142; AY2=8,872. AY1/AY2 have zero
field-label differences; YM2203 has seven. There are no unknown ports.
The first global mismatch therefore concerns ordering between separate chips,
not differing within-chip register/data sequences in this finite replay.

The global failed comparison remains unchanged. Different interleaving can
still alter write timing and PCM; no physical timing, PCM or all-effects pass
follows. No CPU clock, chip clock, game RAM, ROM or RTL was changed. The
diagnostic script is scripts/diagnose_sound_interleaving.py; execution receipt
research/kyros_combat3600_sound_interleaving_run.json records exit0.
