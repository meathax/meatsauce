# Proposed MAME compatibility and limits — 2026-10-11

Kyros/Japan use the existing MAME0.289 compatibility MCU; original undumped/partial Alpha8511 firmware is not fabricated. Stingray uses real T48 firmware and the existing pinned profile constants. Uncertain MCU clock and physical fidelity limits remain open as catalogued in mamebug.md. No new MAME bug closure is claimed here.

Completed PNG texture/display RGB is the visible-frame oracle; post-swap diagnostic drawing-buffer RGB is a separate artifact. No mismatching pixel or RAM data is masked. Final CPU-consumed input phase and exact gameplay gates remain parent-owned; earlier callback-only phase inference must not be used as acceptance evidence.
