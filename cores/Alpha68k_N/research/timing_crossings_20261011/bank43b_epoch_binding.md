# Bank43b fitted-source to canonical epoch proof

Canonical commit `6cafdc7d5edac7a5403ac7224b74c996921de966` is semantically equivalent to the frozen fitted source closure. Native160: **156 byte-identical files + 3 CRLF-to-LF-only HDL files + 1 reviewed QSF overlay**. Origin161: **157 byte-identical files + the same 3 HDL normalizations + 1 QSF overlay**. All paths exist; no unexplained source difference remains.

The only HDL differences are `rtl/alpha68kn_mcu.sv` (26614f -> 2626a0), `rtl/vendor/t48/t48_core.v` (2ad3ac -> 63dcf1), and `rtl/vendor/jt12/jt49/hdl/jt49_div.v` (2c4e8f -> e2258a). Exact raw replacement of CRLF with LF produces each canonical file; no token, whitespace beyond those line terminators, logic or parameter differs. Every 116 actual flattened native HDL assignment matches its frozen source pin and canonical target; full hashes and paths are in `bank43b_epoch_binding.json`.

Canonical QSF SHA256 `57c6729be203f2a8289534ad3e686d842add90fb11d8e75fd5526f3bf10bec31` differs from original QSF `7b560a...` only by the single additive `SDC_FILE constraints/alpha68kn_game_groups.sdc` assignment. Removing that exact line reproduces the original QSF bytes. Canonical overlay SHA256 is `8ef8f941d4c769a0bca7fbafd5aeb04de2c8eee1e4ec4151c02732fdc61c0d8a`, identical to the reviewed native overlay. Both original SDCs and the source closure retain exact bytes. Native effective QSF `029436...` is a relocated/flattened check workspace with RBF OFF and is bound separately; it is not the canonical raw QSF.

This is a **source semantic equivalence proof**, not a byte-identical canonical FIT/rebuild claim. Existing eight-corner reports remain immutable and qualify their exact native input graph. No report was regenerated and no compile, source edit or constraint change was performed. All external timing, physical CDC, current-image gameplay/graphics and hardware/release gates remain open as previously recorded.

HEAD is bound by direct read of the repository HEAD/ref and the existing successful root_commit_v4 receipt. Fresh Git subprocess status was unavailable (permission denied); the clean-status claim is explicitly limited to that root receipt.
