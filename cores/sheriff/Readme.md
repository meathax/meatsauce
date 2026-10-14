# Sheriff for MiSTer

This project supports **Nintendo Sheriff, MAME 0.289 parent `sheriff`, only**. Other games and clones are excluded; there is no family expansion phase.

Canonical checkout: `D:/Arcade/AI/aCORES/meatsauce/cores/sheriff`; compatibility path: `D:/Arcade/AI/aCORES/sherrif`. The template-derived internal Quartus project remains `Nintendo8080.qpf`; the release package is `Sheriff.mra` and the final Sheriff core.

Real 8080/8035 ROM execution, substantial gameplay and sound have scoped simulation evidence. Complete current-source graphics/audio/wrapper acceptance remains open. Pinned development fit passes resource limits, but all-corner setup is −0.008 ns; the isolated placement candidate and endpoint review are in progress. No project RBF has been assembled or tested on MiSTer.

- [Completion plan](plan.md)
- [Progress and evidence](progress.md)
- [Short goal prompt](goal_prompt.md)
- [Sheriff MAME issues](mamebug.md)
- [Sheriff donor contracts](donormap.md)
- [Controls and display features](docs/DISPLAY_FEATURES.md)

Keep `sys/` untouched. Reuse staged donors with original notices; the combined distribution is GPL-3.0-or-later with individual licenses retained. ROMs, credentials and local environment files stay private/ignored. Simulation and exact-source timing/resource gates precede the explicitly requested final build and hardware phase. Historical family documents are archived research, not supported-game promises.
