# Kyros intro audio investigation — 11 October 2026

The reported scream/laugh on MiSTer remains a subjective sound-quality observation; no reproducible audio RTL fault was established. MAME Testers MT02868 explicitly describes an old-woman laugh on coin insertion, and its December 2024 board comparison says that coin sound matches MAME. It does **not** establish what plays with Demo Sounds Off or prove that every intro voice should sound distorted.

## Evidence and limits

- The sound code and speech ROMs match MAME CRC/SHA1. All 256 unsigned DAC codes match `(code - 128) * 128` at MAME's 0.50 route. Kyros's Z80/chip/NMI/export rates are 4 MHz, 2 MHz, 4 kHz and 48 kHz respectively. Signed audio reaches the MiSTer framework correctly.
- The closed real RTL World lifecycle capture's first eight seconds contain 384,000 PCM samples, zero samples at either rail, peak range -27,444 to -820, and no recorded mixer clipping. Its full capture records zero clipped samples. Accepted DAC writes have common 12,000 +/-24 master-clock gaps, consistent with approximately 4 kHz.
- The current audio, mixer, sound-chip, system and T80 sources match that capture's audio closure: 52 files are byte-identical and one donor differs only in line endings. The board delta concerns MCU/debug and Stingray HALT behavior; the Kyros sound clocks, latch, DAC and ROM paths are unchanged. This supports the measured audio-module scope; it is not new whole-image or physical-hardware acceptance.
- That capture used DIP CE: **Demo Sounds On**, since Kyros bit0 is Off=1 / On=0. The release MRA, board profile and generator already implement that polarity correctly. No Off-mode exception was proved or patched.
- A read-only hardware probe found MiSTer currently in MENU and its stored Alpha68k_N.rbf identical to the requested ff4a7268... artifact. HDMI is configured for 48 kHz/16-bit. The active route, runtime filter/volume and exact image loaded when the sound was heard were not established.
- The mix can theoretically saturate with extreme simultaneous source outputs, but the captured scene did not. Eight-bit YM SSG donor quantization also loses very quiet amplitude precision; this is separate from the speech DAC. Neither observation justifies claiming a repair for the reported voice.

## MAME bugs and disposition

The expanded [bug catalogue](../mamebug.md) records historical missing effects, persistent punch noise, clipping and chip-clock corrections plus six additional report dispositions. MT03582 lists Kyros clipping after MAME autosave restoration in a debug build; it is not evidence of this MiSTer issue. MT02868 is original board behavior, while MT03043 concerns removed diagnostic logging. No confirmed intro-specific MAME 0.289 defect was found. The audited current digital clocks, DAC conversion and route calibration already match the applicable reference corrections, so no speculative audio gain, phase, sample-rate or filtering change was made.

## Local recovery evidence

- `D:/Arcade/AI/aCORES/Alpha68k N/research/audio_pickup_20261011/intro_audio_source_audit_v1/report.json`
- `D:/Arcade/AI/aCORES/Alpha68k N/research/audio_pickup_20261011/intro_audio_closure_binding_v1/line_ending_addendum.json`
- `D:/Arcade/AI/aCORES/Alpha68k N/research/kyros_intro_audio_diagnostic_v1/closed_world_legacy_intro_v1/import_manifest.json`
- `D:/Arcade/AI/aCORES/Alpha68k N/research/current_bug_gate_audit_20261011/audio_online_audit_receipt.json`
- `D:/Arcade/AI/aCORES/Alpha68k N/research/mister_loaded_audio_identity_20261011_v1/network_attempt_v2/import_manifest.json`
- `D:/Arcade/AI/aCORES/Alpha68k N/research/mame_cutoff_observer_stage/kyros_demo_metadata_audit1/import_manifest.json`

Primary references: [coin/laugh PCB comparison](https://mametesters.org/view.php?id=2868), [autosave/debug clipping](https://mametesters.org/view.php?id=3582), [MAME 0.289 driver](https://github.com/mamedev/mame/blob/mame0289/src/mame/alpha/alpha68k_n.cpp).

If a reproducible difference remains, capture the exact intro moment with its DIP byte and separate accepted DAC writes from PSG/FM output. Change a producer only after that comparison identifies a fault. Preserve the expected original laugh.
