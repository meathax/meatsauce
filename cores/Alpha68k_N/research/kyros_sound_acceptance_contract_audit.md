# Kyros sound acceptance audit
P5 requires one source-qualified action sequence, command/latch/IRQ/NMI/register events, tone rates, numerical balance/clipping and a short WAV. It explicitly excludes phase-identical MAME/JT PCM. An unsampled exact death-animation edge is not an additional gate.

World finite swing/cleanup, ROM-qualified depletion/lives consumption and nonvacuous actualCPU active-noise reset remain covered. Combat3301 actualCPU output contains2677137 samples at48000Hz with zero clipping. AY1/AY2 writes and field labels agree; YM bytes agree but seven field-label differences/global reorder remain. Independent current seven-vector mixer and corrected1800 component replay qualify finite calibration only.

Japan720 exits0 and produces583925 samples/48000Hz without clipping. However retained MAME before720 contains114 port writes versus native406; common bytes agree. This is a concrete reference/input epoch gap requiring diagnosis before an RTL fix or repeated replay. Exact applied-input comparison and first additional native write are in the JSON.

Hit/jump/pickup/game-over/restart need source-qualified semantic windows. Reuse retained combat/idle RAM/events first, compare DAC writes, and export existing WAV snippets. Capture one legal missing-action/profile sequence only if retained evidence lacks it. Do not repeat qualified punch/depletion/reset. Broad B03-B06/P5/graphics/physical acceptance remains open.
