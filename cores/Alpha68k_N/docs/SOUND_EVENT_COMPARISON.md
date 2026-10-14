# Ordered sound-event comparison

scripts/compare_sound_events.py compares actual MAME CPU writes from events.csv
against native RTL audio_events.csv and main-CPU epoch_events.csv. Run with
the MAME capture directory, RTL capture directory, completed field count and
JSON output path. It reads only the requested prefix and stops at the first
later field, preserving ordering and accepted bus byte masks.

It compares sound-chip port writes and main sound-latch writes independently.
It reports both ordered address/data/mask differences and callback field-label
differences, retaining the first differing event. A mismatch exits 2.
Hashes describe the exact accepted event sequences. It never substitutes a
CPU, injects sound commands, drops differing events or tolerates unequal data.

research/kyros_idle_sound_prefix.json covers the first 139 completed fields of
the live hard-DIP death replay. All 114 sound port writes and all four main
sound-latch commands match, including callback field labels. This is startup/
coin evidence; field 139 precedes start and does not qualify combat or death
effects. Native input/ROM/ELF/source manifests are bound by
research/kyros_idle_death3601_job.json, and the corrected MAME reference by
research/kyros_idle_death7200_v2_exit.json.

After the long run completes, compare its entire completed prefix and inspect
event windows around the observed death/continue/game-over sequence. Preserve
any first difference for diagnosis. Other requested punch-hit/pickup/jump
effect windows and reset remain separate work. PCM phase/resampling, tone
frequencies, listening and broad paired MAME_EXACT are outside this script.


DAC extension: when the native capture has sound_bus_events.csv, the
comparator also compares actual accepted DAC writes at Kyros 0xe004 or
Stingray 0xc104 against MAME sound_memory observations. The output field
dac_capture_available is false for older captures without this trace.
Those captures qualify only the explicitly reported chip/latch domains.
No missing DAC trace, PCM phase or unobserved effect is counted as a pass.
