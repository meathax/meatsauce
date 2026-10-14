# Kyros stage5 / ending fixture discovery

The required B01/B02 late-scene fixtures remain open. Generic color-ff and
strip overlap tests do not replace stage5 lamp/blocks or actual ending text.

Source parent4d0fe55. The author-hosted cheat0279 archive returned HTTP403
through both urllib and native curl. No current archive was downloaded.
Historical definitions were obtained from the public imame4all archive;
URL, Git blob identity, byte hashes and both Kyros XML definitions are pinned
in `research/late_scene_cheat_historical_definitions.json`. The downloaded
working copy is ignored. There is no level-select definition. Both sets have
the same health/ammo/rollkick/speed candidates, requiring actual MAME checks.

`sim/mame/capture_late_scene_candidates.lua` drives real MAME CPUs but also
writes those four RAM bytes explicitly. Every changed fixture byte is logged
separately. This is scene discovery only, never RTL gameplay acceptance.
`scripts/record_late_scene_candidates.py` records actual process IDs,
commands/source hashes, terminal exit, all-frame observation and full PNG,
normalized57344-pixel RGB,8192-byte sprite and4096-byte work-RAM assets.

The first `kyros_late_scene_candidates36000` run completed36000 fields,
exit0, with all six capture-integrity checks passing in60.94 seconds.
It retained122 snapshots. Actual inspected images6000/18000/35999 remained
in the first outdoor area, with the player pressed against the right edge.
Thus neither stage5 nor ending is qualified. The player earned different
scores, but explicit RAM writes preclude a legal-playthrough claim.
Evidence: `research/kyros_late_scene_candidates36000_verification.json`,
job/exit receipts and ignored `sim/captures/kyros/late_scene_candidates36000`.

The route used raw input bit0 for up. The physical display is ROT90, and this
raw-field API bypasses the keyboard front end. Input macros confirm bit2 is
RIGHT and bit3 LEFT, not the unswapped bit ordering. Next test the raw-left
route against actual successive images before asserting its displayed
direction or attempting scene identification. No inferred core input fix,
stage-number guess or late-scene acceptance follows from this first run.

The finite raw-left probe also completed,3600 fields, exit0, all six capture
checks passing in6.196 seconds. Actual900/3599 images show the player near
the left edge of the same first courtyard, not a later scene. Therefore do
not assert raw-left means displayed up. Its job/exit/verification receipts
are `research/kyros_late_scene_candidates3600_raw_left_*.json`.
Next retain raw-up but remove the periodic sideways steering, which displaced
the player from the central stairs; use a separate centered-up namespace.

The centered-up run completed36000 fields, exit0, all six integrity checks
passing in64.207 seconds. Actual24000/35999 images still show the first
outdoor area with the player at the right edge. Removing sideways steering
did not establish progression. Preserve this evidence and test pure raw bit2
(`centered-right`) before assuming the displayed direction from port names.
This does not qualify B01/B02 or justify a production input-mapping change.

The centered-right run completed36000 fields, exit0, all six capture checks
passing in61.900 seconds. Actual19800/35999 images show the first courtyard's
lower/right corner. Together these routes give usable direction evidence,
but no late scene. Next try alternating raw bits0/1 to stay near the central
stairs rather than continuing against a corner. This is a route hypothesis;
keep its scene outcome separate from asset-integrity checks.

The6000-field stairs-zigzag attempt also completed, exit0, all six integrity
checks passing in11.321 seconds. Actual5999 still shows the initial outdoor
area. Stop blind route sweeps: these attempts do not qualify late scenes.

Official unidasm now has a hash-bound cache of the pinned131072-byte Kyros
program ROM at ignored
`sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm`.
`research/kyros_rom_disassembly_candidates.json` pins tool/ROM/cache hashes.
Source inspection rejects0x20912 as a stage counter:9f30 initializes it to1,
iterates four objects at A4+=0x30, and stops at5. The routine1a1e instead
advances byte($101,A6) through3,1,2,4,5,3, incrementing($100,A6) on wrap;
1ae0 uses($101,A6) to select the scene-entry background color. This is a
scene-selector candidate, recorded with exact instructions in
`research/kyros_scene_selector_analysis.json`, not a late-scene pass.

Next trace this source path and make a finite MAME-only debugger fixture
for the candidate fifth scene. Require valid A6=0x20000, SR, SP and return
stack context before redirecting any PC. MAME exposes the stack register as
`SP`, confirmed in0.289 m68kcpu.cpp. No debugger jump has happened yet.
Identify actual stage5 lamp/blocks and ending content, then compare the full
RTL-rendered frame. These debugger fixtures cannot replace real RTL CPU
attract/gameplay or close whole-game acceptance.

Source parent361e94e. Guarded candidate5 initialization succeeded at frame900:
PC0x9e90, SR0x2014, A6=0x20000, SP=0x20ff4, return0x9dde. The fixture writes
selector3->5 and redirects MAME to1a66, including the source's transition
setup before1ac2. CPU context remains valid afterward. The resulting corridor
has wall lamps/flames and differs from the earlier outdoor scene. All2400
observed fields and10 snapshots are intact; no real RTL CPU acceptance is
claimed from this RAM/register fixture.

`verify_late_scene_renderer.py` reuses private actual ELF39b91147..., verifies
all11 original source pins and equality of9 shared native DUT sources, then
compares fields1200/1500/1800/2100/2399. All5 complete57344-pixel fields match
MAME exactly; internal reference comparison, deadlines and overflow checks
also pass. No RTL rebuild was needed. Receipt:
`research/kyros_candidate5_entry_renderer_verification.json`.

The color-ff clipped-tile counts are0/4/4/4/4. To test whether this actually
exercises B01, `probe_scene5_color_ff.py` replaces CLUT255 tile words with the
Kyros sentinel in a separate RAM-only negative fixture. At1500 this produces
zero visible differences; the intended graphics rejection does not occur.
The negative-probe receipt deliberately records `passed=false`. Those early
tiles therefore do not establish visible old-predicate sensitivity. B01 lamp/
block coverage remains open. The bug-report attachments failed web retrieval;
no downloaded-reference image or visual identification pass is claimed.

Next traverse the initialized corridor to the later head/lamp region, or
locate its camera/room state from ROM. Preserve these exact positive frames
and the nonvacuous-coverage failure. `docs/bug_coverage.json` is a partial
coverage record, not the final all-bug P7 audit. Japan and ending remain due.

The moving corridor attempt completed12000 fields, guarded setup and all
integrity checks pass. Full RTL renderer comparisons at3000/6000/9000/11999
also match every pixel. Clipped color-ff counts16/28/28/32 still give zero
visible effect when suppressed at11999. Keep that second failed negative
probe; neither count nor traversal duration establishes B01 coverage.

Source now identifies a direct late-room path. Routine1b90 selects an
8-byte descriptor from1c0a using the high-byte room cursor in($110,A6) and
the scene selector. Scene5's table starts1d4a. Records8/9 are both
`090060b068f00000`: room word0900, spawn60b0, layout68 and flagsf0.
The routine stores the descriptor into0110/0120/0122/0112, copies player
state through1400, and branches1660, which re-enters1ac2 for a live player.
This source path is pinned in `research/kyros_scene5_room_descriptors.json`.
Next use a second guarded MAME-only setup to select that actual room9
descriptor, rather than guessing camera coordinates or continuing routes.

The guarded late-room setup now succeeds for both ROM sets. Actual MAME
images show the red-head chamber and block structures, with selector5 and
room0900 in the saved RAM. World capture3600 and Japan capture3601 each pass
all nine capture/setup checks. The first Japan3600 attempt deliberately
failed both setup guards because the World return/entry addresses differ;
its failed receipt is retained. `generate_scene_fixture_profiles.py` derives
the Japan entries1a3c/1b66, normal return9db4 and descriptor table1be0 from
unique program signatures, the JSR, wait loop and PC-relative LEA. These are
42 bytes earlier than World's1a66/1b90/9dde/1c0a, with both identical late
descriptors independently validated. Program hashes and derivations are in
`research/kyros_scene_fixture_profiles.json`.

The unchanged actual renderer/SDRAM ELF matches all57344 RGB pixels at
World1500/1800/2400/3000/3599 and Japan1500/1800/2400/3000/3600. All original
source pins remain current; internal decoder comparison, deadlines and
overflow checks pass. Receipts:
`research/kyros_candidate5_lastroom_renderer_verification.json` and
`research/kyrosj_candidate5_lastroom_renderer_verification.json`.

Separate RAM-only obsolete-color-filter probes at1500 change500 visible
pixels in each ROM set. Each intentionally fails its complete MAME RGB
comparison while keeping internal reference/deadline/overflow checks valid,
so the negative-probe receipt passes its expected-failure contract. See
`research/kyros_candidate5_lastroom_renderer_color_ff_suppression_001500.json`
and the corresponding `kyrosj_...` receipt. This qualifies a finite,
regression-sensitive B01 graphics case for both sets. Earlier zero-effect
probes stay failed. No production RTL/ROM changes, actual RTL CPU late-stage
acceptance or equivalence to unavailable bug-report attachment images are
claimed. B02 ending content and the complete P7 audit remain open.

The true ending is separate from low-ROM359a's stage-clear bonus screen.
The natural main loop calls1e000; state($d10,A6)=5 dispatches1e81a, where
($d11,A6)=2 selects1eca8. With($d12,A6)=2 it runs1edae, clears the staff
buffer, initializes credits, then advances d11 to3. Routine1edd4 calls1f004
every eight iterations to copy ASCII glyphs from1f036 into411b0 onward.
`generate_ending_fixture_profile.py` pins these exact blocks for both ROM
hashes in `research/kyros_ending_fixture_profile.json`; their high-ROM ending
code is identical even though the normal wait-context addresses differ.

Added optional `--ending` to the existing isolated capture runner. It requires
the guarded final-room fixture, then at1800 requires the same normal CPU,
SR/SP/return context and selector5/room0900. It logs three explicit state
byte writes at20d10/20d11/20d12 and lets the normal ROM dispatcher execute;
there is no additional PC redirect. The5400-field Kyros capture passes all
eleven integrity/setup checks, including actual `KAIROSU` glyph words in
saved sprite RAM while the staff-roll state is active. Its actual2400/3600
images show characters covering the credits, consistent with the behavior
that B02 requires preserving. Evidence:
`research/kyros_late_scene_candidates5400_centered_up_scene5_lastroom_ending_verification.json`.

The unchanged actual renderer/SDRAM matches all57344 pixels at
2400/3000/3600/4200/5399, with zero internal-reference mismatches, deadlines
or overflows. `research/kyros_ending_renderer_verification.json` retains
complete frame hashes and source pins. No overlap mask or priority correction
was introduced. This qualifies finite B02 ending graphics/reference coverage;
the explicit MAME fixture does not substitute for real RTL CPU progression
to the ending or close the complete P7 audit.
