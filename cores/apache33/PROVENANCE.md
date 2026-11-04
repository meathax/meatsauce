# JTAPACH3 (Apache 3) source staging

- Upstream: https://github.com/jotego/jtcores branch `andrea-cores`
- Commit: 47b46e40f57775733ed6f6e06c61f9f021168b49 (2026-11-03)
- Author: Andrea Bogazzi (asturur); release RBF/MRA in https://github.com/asturur/Mister-cores (`_Arcade/cores/jtapach3.rbf`, commit c01ac77d8c "swapped apache 3 with fixed build")
- Sparse checkout: `cores/apach3`, `modules/jtframe` (+ repo root files)
- Submodules (from cores/apach3/cfg/files.yaml, transitively resolved, nothing missing):
  - modules/fx68k  1217ab8dc600de070c6adb71ea6fe69de8855362
  - modules/jt51   2ca6601e6e69e1a3a529920506ee0657ccd30513
  - modules/jt6295 7d76b0be8cd8f85f3ae741178c9830b20e2071a1
  - modules/jt8255 3bb5f7ea461fc7d72b847ec55ce997e5d5bc1754
- Note: the RBF itself may be built from a later/local revision; the source commit is not bound to RBF hash.

## Local changes (2026-11-04)
- cfg/macros.def: JTFRAME_OSD_NOLOGO + JTFRAME_OSD_NOCREDITS.
- target/mister/hdl/sys/osd.sv: NOLOGO uses the stock Template_MiSTer OSD mixer (colour 3'd4) and omits the JT logo instance.
- hdl/jtframe_board.v: NOCREDITS undefines JTFRAME_CREDITS (also blocks the JTFRAME_CHEAT re-enable).
- src/jtframe/macros/macros.go: NOCREDITS removes the release-mode JTFRAME_CREDITS after macros.def parsing (no CONF_STR credits option).
- target/mister/cfgstr: "Show credits in pause" OSD option suppressed whenever JTFRAME_OSD_NOCREDITS is set.
- src/jtframe/mra/mame2mra.go: NOCREDITS drops the "Core credits" MRA button (+ test buttons_nocredits_test.go).
- Beta: not required (apach3 not in .beta.yaml, no jtbeta.zip in MRA, no unlock key). Unchanged.
Full patch and verification: ../build/osdcredits/{jtapach3-osd-credits.diff,receipt.md}
