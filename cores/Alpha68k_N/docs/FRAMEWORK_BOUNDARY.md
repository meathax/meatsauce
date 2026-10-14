# Shared system to MiSTer framework

Alpha68k_N.sv now instantiates alpha68kn_system, the same actual fx68k/T80,
scanline renderer, palette, SDRAM controller and audio system executed by
the native gameplay harness. Its old background-only board connection and
idle graphics read port are removed. files.qip includes the system, renderer,
video ROM and existing audio QIP. This is source integration, not P8 completion.

The existing ROM header/end-of-download gate holds game reset until the
graphics FIFO is drained and SDRAM initialized. Refresh is owned by the shared
system and continues during download/reset. The framework receives the
palette-aligned RGB/CE/sync/blank signals and mixed signed mono samples.
HPS download backpressure still comes from the real graphics FIFO.

Pinned sys/arcade_video.v supplies gamma, native output, scandoubling, HQ2x and
CRT scanline effects. Its screen_rotate module supplies clockwise ROT90 HDMI
framebuffer writes when MISTER_FB is defined, while preserving native analog
output. Horizontal orientation or direct_video disables rotation; aspect is
3:4 when rotated and 4:3 otherwise, with a full-screen option. Renderer MCU
flip remains upstream; rotation does not apply a second flip.

All game and video logic uses clk_sys with enables. SDRAM's physical clock
remains the existing phase-shifted PLL output. Framework audio/DDR/framebuffer
crossings retain their existing interface contracts and still require the
complete framework simulation and later timing/CDC qualification. The
elaboration PLL stub is deliberately not a frequency/phase model.

sim/lint_wrapper.sh checks the real system and framework in native and
MISTER_FB/MISTER_FB_PALETTE configurations with elaboration-only HPS/PLL
interface stubs. sync_fix is extracted verbatim from pinned sys/sys_top.v
into a temporary snapshot. Verilator 5.050 rejects the framework hq2x
procedural assignment to its implicitly net-typed Result output; the check
uses -Wno-PROCASSWIRE, matching the indexed legacy-elaboration lesson, without
editing sys/ or disabling RTL assertions. Initial missing-sync and
PROCASSWIRE failures are preserved alongside the corrected exit-0 receipt.

Evidence: research/wrapper_lint_result.json and wrapper_lint_inputs.sha256;
full logs under sim/build/wrapper_lint_{native,framebuffer}.log. There are
75/92 warnings, chiefly in pinned donor/framework code. The wrapper itself
reports a missing timescale warning; no wrapper pin/width warnings were
reported. This is not a warning-free design or an execution, resource or
timing pass. Framework RGB, scandoubled/rotated captures and DDR writes must
still be checked in real simulation, including the indexed generate-scope
black-output risk. DIP menus, CRT Adjust, safe pause/hiscore and final feature
qualification remain open. Quartus is disabled by the user's hold.

## Executed video-boundary diagnostic

sim/framework_video.sv and framework_video.cpp feed a real native gameplay
capture (field 360, SHA-256 c70ec6bd6464f4da16a10cbc23eb328327aea1a578a4089eade1ae6f6e39178f)
through the actual pinned arcade_video/gamma/scandoubler/HQ2x chain. This
fixture checks that boundary, not CPU boot or changing game frames. It repeats
one field while the framework measures sync polarity; the last three fields
are compared. There are no RGB masks or temporal image-offset searches.

The original source build exits 0 and diagnostic run exits 1. The input RGB
register has zero differences over 172,032 active samples per mode. Native
output has the expected 256x224 pixels but is black (158,295 differing
nonzero pixels over three fields). All six modes produce correct pixel
counts/sync: native 57,344 per field; HQ2x 512x448 = 229,376; CRT effects and
forced scandoubling 256x448 = 114,688. This reproduces the indexed generate
scope problem: video_mixer's R_in/G_in/B_in are declared inside generate
branches and referenced outside, where Verilator creates undriven nets.

The explicit scope-adapter option changes only a temporary simulation copy:
sim/normalize_framework_scope.py moves those existing declarations to module
scope, preserving each conditional assignment, width and all sequential
logic. It fails if the pinned source block changes. Original framework SHA
31ed2c917bd6680b4d60328e71a4f28015bd5fcec21e15b290eacec88971167d;
normalized SHA 183a46fc94d4dde6e884b0dd6a2f5ea79e14f2d400af2426d8790241186f0a9d.
The native RGB comparison then has zero differences; all six mode counts,
sync and input-register comparisons still pass, with nonblack output.
Non-native modes' native RGB counter is not an HQ2x pixel-equivalence test.

The first normalized tool call failed after creating a complete result but
did not preserve a terminal receipt. The process handle was absent; a rerun
of the same immutable ELF recovered an authoritative exit 0. Evidence:
research/framework_video_run.json and framework_video_result.json preserve
the unmodified failure; framework_video_normalized_run.json and
framework_video_normalized_result.json preserve the conditional result;
framework_video_scope_adapter.json and both input manifests bind the models.
This establishes the temporary model's boundary behavior, not Quartus's net
binding or hardware behavior. Pinned sys/ is untouched. P8 full-wrapper
execution, DDR rotation writes, gamma programming, CRT/pause/hiscore and
resource/timing gates remain open.
