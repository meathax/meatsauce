# Kyros temporal graphics diagnosis
Native CPU runs remain the execution evidence. No masks, image-frame shifts,
changed game clocks, ROM patches or scripted CPU/game responses are used.

## Field60 backdrop
The real61-field diagnostic exits0 with no invalid pixel/deadline/bus metrics.
One accepted low-byte write changes0x060000 from64 to80 at beam99,97.
PROM colour64 is187,119,34;80 is255,34,102. Pixels before that write total20835.
Their old colour followed by the new colour reconstructs all57344 actual RTL
pixels exactly. The canonical atomic MAME image uses final colour80 everywhere
and differs20835 pixels. This is a measured mid-field transition, not a failed
colour lookup.

A fresh real MAME361 capture reproduces361 state rows,741506 original event
records and the60/300/330/360 images. Its functioning tap reports the same
write/data/mask at81,97. A MAME timed reconstruction therefore differs18 pixels
from native. Keep that horizontal bus-phase difference open; do not erase it
by moving the image or adjusting clocks. The static immediate-write candidate
is only an investigation aid until actual execution/source timing is established.
Evidence: research/kyros_background60_causal_verification.json and
research/kyros_reset_raster361_v3_verification.json.

## Field360 sprite writes
The canonical image still differs2104 pixels, despite identical final sprite
RAM. All position/tile write areas must be included; an initial area whitelist
omitted tiles1/2/3 and is preserved as invalid evidence.
The complete interval contains10455 MAME and10453 native writes. The ordered
gap analysis matches10452 writes, retains a relocated0x411b4 sentinel write
around VBlank, and two MAME end-of-window writes. These are not silently dropped
or called identical CPU timing. Preserve the physical coordinates and first
differences. A full timed renderer replay is still required to explain all
pixels and distinguish prefetch/raster effects from a real fault.
Evidence: research/kyros_reset360_write_stream_comparison.json and
research/kyros_reset360_write_gap_analysis.json.

## Recorder failures and recovery
The first supplemental observer and second added-column attempt returned no
write records; successful MAME process exits were not trace passes.
MAME0.289 exposes time_until_pos, frame_period and pixel_period rather than
hpos/vpos methods. The existing beam helper already returns Y,X. The third
attempt uses both values within the original callback, with positive coverage.
Failed loaded code/receipts and the zero-coverage results are retained.

The first copied launch command reused the old WAV output path. Its361-field
audio was preserved under reset_raster361. A fresh canonical960 recording
reproduced all960 state rows and35 displayed-image checkpoints; its entire
361-field PCM prefix is identical. The verified fresh960 WAV restores the
original reference path with a new documented hash. Future copied commands
retarget WAV/AVI/MNG outputs into their own capture directories.
Evidence: research/kyros_reset_audio_recovery_verification.json.
