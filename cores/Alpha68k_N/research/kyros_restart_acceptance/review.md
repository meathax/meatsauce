# Legal death and restart reference

Pinned MAME completed 3901 fields with exit 0. All 13 verifier checks pass: every recorded state row through field 3600 and each retained displayed checkpoint exactly matches the original idle-death reference. Only actual PCB coin, start and right inputs extend the sequence; no CPU or memory changes are used.

Use `sim/captures/kyros/idle_death_restart3901/frame_states.csv` as the native replay input. It retains IN1=206 (hard difficulty, default lives). Lua changes ports after recording a field, so the actual second coin is present in rows 3621–3626, start in 3661–3666 and right in 3741–3770. Do not manually shift this CSV.

The decisive displayed checkpoints are GAME OVER at 3360, title at 3600, the second stage introduction at 3690 and courtyard gameplay with the player at 3900. Fields 3740 and 3770 are black transitions: the right pulse proves input application but does not prove movement. Canonical `.display.rgb` files use the transform uniquely qualified against the original byte-exact displayed reference; raw RGB is separately retained.

`verification.json` preserves all 44 snapshot pins. Work and sprite memory files are actual observations with no guessed semantic offsets. Successful jump, enemy hit and pickup remain unknown; earlier legal controls and score changes do not independently prove these actions.

This qualifies the MAME oracle only. Native restart, full P5/P7 acceptance and the final combined graphics/resource/timing gates remain pending. Existing combat graphics failures and IRQ ordering evidence are preserved. The parent owns the one merged-core native build and replay.
