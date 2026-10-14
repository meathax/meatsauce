# B13/B14 observed sound addresses

`audit_sound_address_usage.py` makes one pass through the existing complete
3600-field real MAME combat event stream. It verifies the full frame sequence,
completion marker and exact observed-port hash used by the completed actual
RTL combat3301 run. No new game capture, RAM changes or CPU substitution was
needed. Event/port/driver/executable identities are retained in
`research/kyros_sound_address_usage3600.json`.

The pinned Kyros sound map uses RAMc000..c7ff. Lowerc000..c3ff has2325198
writes across all1024 addresses,2323650 after field0,1991777 nonzero. Upper
c400..c7ff has exactly1024 writes across all1024 addresses, each zero; it has
no nonzero or repeated-address writes in this capture. This is finite write
usage evidence. It is not a sound-RAM read trace or a proof of original
physical capacity or alias wiring.

Known virtual values differ in corresponding1KiB alias pairs; eight ordered
witnesses are retained. Those witnesses do not prove both addresses are read
or that a hardware alias would change gameplay. In particular, do not infer
a physical2KiB requirement or implement a1KiB correction solely from this
write trace. Preserve MAME's2KiB allocation until read/wiring evidence supports
an alternate board model. The two2114 PCB notes remain an explicit limit.

All five documented ignored ports e006/e008/e00a/e00c/e00e receive actual
writes. The receipt records counts, value histograms and first/last fields
for each, including inactive odd addresses in the whole nopw range. Preserve
the current0.289 digital nopw behavior. Observed NMI/RST-associated activity
does not identify an analog filter, physical clock or DAC circuit, and does
not by itself qualify punch/jump/pickup effects or complete audio fidelity.

This completes a finite existing-capture B13/B14 usage/disposition check.
The physical limits, missing read coverage, full per-profile sound checks
and final resource/timing/hardware gates remain explicit.
