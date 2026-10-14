# Sheriff audio control timing

The current production controller changes the two 74123 duration registers
atomically on one master-clock edge (`rtl/n8080_mcs48.sv:75`–82). A mono0
trigger loads duration0 and clears duration1; a mono1 trigger loads duration1.
The connected SN enable is their logical OR (`:71`). A mono1-to-mono0
handoff therefore has no sampled disabled interval. The SN wrapper restarts
its attack capacitor only on a newly enabled edge
(`rtl/sheriff_sn76477.sv:75`).

MAME 0.289 invokes stop-mono1 before start-mono0, updating SN status after each
setter. Its SN enable setter resets the attack capacitor on re-enable.
The complete saved mixed command stream produces 132 envelope starts under
that source order and 106 under atomic updates. The two model projections
differ on 644,340 WAV samples, beginning at 831,863. This verified software-model
difference does not determine which control pulse the Sheriff PCB supplies.
See `docs/evidence/sheriff_mixed_sound_checkpoint.json`.

The related Exidy drawing 77-3368-11 (1-6-80) connects U5 outputs through two
diodes to an SN enable node with a 10kΩ pullup. It has a shared trigger/clear
wire, but does not establish the Sheriff revision or the complete upstream
signal polarity. See `docs/evidence/sheriff_sound_enable_network.json`.
A shared wire does not by itself establish simultaneous active trigger and
active clear edges.

[TI SDLS043, March1988, page5](https://www.ti.com/lit/ds/symlink/sn74123.pdf)
lists SN74123 B-to-complementary-Q falling propagation at 27ns typical/36ns
maximum and clear-to-complementary-Q rising propagation at 30ns typical/40ns
maximum. Test conditions are 5V, 25°C, external capacitance 0, output load 15pF,
external resistance 5kΩ and load resistance 400Ω. These separate-path values
do not guarantee relative ordering: minimum delays are unspecified, actual
loads differ, and input polarity still needs qualification. They also do not
specify SN76477 enable threshold, node capacitance, or minimum pulse required
to discharge/restart its envelope.

No synthesizable timing change follows from this evidence. Inserting one
50.4MHz clock of disable would choose 19.84ns without a qualified physical
pulse or SN response. The independent reference oracle must retain MAME
setter order, while the native regression must retain the production
controller's atomic state.

The receipt-backed focused connected replay is
`tools/qualify_mixed_audio_connected.py`, with source top
`sim/mixed_audio_connected.sv`. It instantiates the actual production
controller, BSD T48 kernel and real 8035 ROM; it does not substitute a timer
shadow or force MCU state. Frozen actual 8080 latch writes retain the ordinary
two-player scenario identity
`sim/inputs/sheriff_cocktail_two_player.csv`
(SHA256 93df2be1a9e143b9daff0c9176ee07d7c77e7e15fe94bda44630177d253eb6c4).
The old-gain output must reproduce every saved full-board PCM sample and
every connected sound-PC/P1/P2/DAC transition. The corrected output must
equal the separately qualified mixed SN replay plus the actual executing
MCU's DAC. The result and actual exits are recorded in
`docs/evidence/sheriff_mixed_audio_connected.json`; recovery is
`_checks/agent-audio-current-mixed-20261010/`.

This closes only the scope explicitly stated by a successful receipt.
Fresh main-CPU execution, full-wrapper mixing, physical retrigger timing and
whole-audio acceptance remain separate. The prior mixed component's missing
OS receipt remains UNKNOWN; the new connected replay cannot repair it.

The connected mixed prefix completed with actual native/workflow exit 0.
All 1,439,875 samples and 1,768 PC/P1/P2/DAC changes match the frozen old
board and current-gain prediction; 109,106 PCM samples change exactly as
predicted. The controller emits 38 state changes and 17 enabled edges.
At tick 1,455,137,495 mono0 clears active mono1 while enable remains high;
at tick 1,481,613,520 mono1 overlaps mono0, again without a disabled interval.
Both timers are idle by tick 1,511,800,600. Source, fixture, model and report
hashes verify independently in
`_checks/agent-audio-current-mixed-20261010/independent-verification.json`.
This qualifies the finite connected delivery; it leaves the physical
132-versus-106 reference-control question and whole-audio gate open.
