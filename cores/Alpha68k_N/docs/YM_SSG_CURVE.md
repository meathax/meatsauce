# YM2203 SSG transfer correction — 2026-10-09

The supported MAME 0.289 observer, sim/mame/trace_sound_components.lua, enables boolean device hooks and consumes emu.register_sound_update. All 1,800 CPU-state rows and the mixed WAV equal the original recording: observation left execution unchanged. Raw producer streams run at different sample rates from RTL 48 kHz; finite source moments establish no phase/resampler/physical-board exactness.

At seconds15/20/29 the old internal YM SSG RTL/MAME AC RMS ratios are1.262299/1.141838/1.251674; FM ratios are approximately0.988/0.994/0.989 and standalone AY outputs are much closer. See research/audio_component_comparison.json and audio_component_curve_before.json.

The pinned JT03 donor selects compressed SSG bank1. Its fixed volume indexes {volume,volume[3]}; YMFM selects2*volume+1 except zero. scripts/stage_audio_sources.py now propagates SSG_COMP through JT03/JT12, adds bank5 from MAME0.289 ymfm_ssg.cpp, and conditionally uses YM indexing for bank5. alpha68kn_soundchips.sv selects5. Donor defaults remain1; pins, notices, original/staged hashes and transfer source remain in rtl/vendor/audio_sources.json. No clocks, timers, FM algorithm or global gain were adjusted.

The table rounds YMFM_amplitude*255/16382 into the donor's eight-bit interface. Quantization, donor phase/noise and stream resampling remain fidelity limits; an output transfer correction proves no CPU/MCU behavior.

The first adapted replay exited0 but failed fidelity: CRLF donor bytes prevented table insertion and SSG was silent. Its receipt and research/audio_component_curve_after.json remain. Staging now normalizes only adapted files and checks all32 inserted entries; the comparison exits2 for missing activity. The corrected replay completed1,800 fields/37,908 events/1,459,814 samples, exit0, with zero PCM rail samples. SSG AC ratios at seconds15/20/29 are1.004409/0.981642/0.994365; the earlier ratios were1.262299/1.141838/1.251674. The component activity guard passes. See research/audio_component_curve_fixed.json and audio_ymcurve_fixed1800_qualification.json.

A fresh native system build also failed when WSL's4 GB /tmp could not hold its PCH. Only the owned failed snapshot was removed, with research/system_failed_snapshot_cleanup.json; failure/inputs remain. sim/build_system.sh accepts ALPHA_BUILD_TMP; its corrected build on /mnt/d/vibes/fpga/temp passed. The full-system attempt with silent SSG was explicitly stopped using verified owned PIDs and is unqualified.

The combined WAV AC RMS ratios at15/20/29 are1.04128/1.01463/1.01715. Quiet means agree within one signed sample unit. Combined residuals and source sample-rate/phase differences remain unqualified; no whole-audio exactness claim. Only trailing whitespace was cleaned after the build snapshots; eight normalized source comparisons match, with no macro-continuation cases, in research/ym_curve_whitespace_equivalence.json.

Next: qualify current-design Kyros/Japan runs and finish explicit effects. Death/game-over/reset effect coverage and physical audio remain open. Quartus remains disabled.
