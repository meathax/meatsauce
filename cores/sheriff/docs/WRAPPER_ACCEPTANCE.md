# Sheriff wrapper acceptance scope

Updated 2026-10-10. Static audit evidence:
`evidence/sheriff_wrapper_acceptance_20261010.json`. Actual process receipt:
`../_checks/wrapper-acceptance-20261010/verification.json`.

The fresh canonical-root audit validates the sole parent Sheriff MRA against eleven
private chips, CRC/SHA1/lengths, explicit CPU padding, packed 0x4800-byte payload,
sound/PROM offsets, named HPS buttons, lives/cabinet mapping and the production
three-byte high-score descriptor. No ROM bytes appear in the receipt.

`tools/` is a junction to the canonical Sheriff directory inside the meatsauce
repository. The audit's existing resolved ROOT uses that valid Git inventory;
absence of .git above the alias path does not establish an audit defect.
No tooling, production RTL or MRA change is needed for this audit.

Reuse controls protocol, guarded gamma, display/rotation/scale, high-score
power-up/restore/upload and centered HPS input evidence for unchanged source and
their recorded component scopes. Hash mismatches stay explicit and cannot become
current full-wrapper passes. Separately, retained sheriff_platform_hps_smoke.json
binds a 30ms real full-wrapper smoke with compiler/native/producer exits zero,
18,432 ROM addresses, P1/P2 digital transactions and reset/release. These checks
provide no complete lifecycle or moving-picture/audio equality claim.

At the audited source, OSD pause is unconnected in Nintendo8080.sv: line87 defines
`game_paused=board_paused||hs_pause`; OSD_STATUS goes only to persistence (line132).
Menu status bit30 is free between autosave29 and rotation31. The smallest manual
OSD pause integration adds a pause selection at bit30 to the shared board pause
request. A menu-open policy, if offered, must gate OSD_STATUS with its documented
selection and preserve persistence's OSD-open upload behavior. The parent owns
the top-level change and real-wrapper pause/resume, score RAM ownership and timing
verification. A later source edit requires its own source identity/qualification.

Complete current-wrapper P1/P2 lifecycle, later rounds, mixed sound, zero unexplained
graphics mismatches, exact final-source resource/all-corner STA and final hardware
acceptance remain open under plan.md.
