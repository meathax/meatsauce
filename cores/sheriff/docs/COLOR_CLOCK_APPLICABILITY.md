# Color-clock applicability

The original Sheriff parts layout identifies **TWG-I/O, PI-500932**; it provides component placement, not CLK9 wiring. The related primary drawing identifies **Exidy BANDIDO I/O PCB SCHEMATIC,77-3367-11,Sht1of1**. Neither gives an exact Nintendo TWG revision cross-reference. Title crops preserve source coordinates, dimensions and hashes in the evidence report.

Two bounded alternate primary leads concern modified conversions: a [first-person B/W Sheriff owner account](https://forums.arcade-museum.com/threads/nintendo-sheriff-questions.512351/) and a [conversion repair account](https://jammarcade.net/sheriff-conversion-repair-log/). They do not prove the parent color board’s CLK9 copper route; the latter page open failed. No further alternate search or retained-manual refetch was performed.

The physical16-clock route is qualified for the related Bandido drawing. Applicability to the exact Sheriff parent video PCB remains open. PROM pair inequality does not establish a MAME bug.

Passive analysis reuses the exact68-field IRQ integration artifacts. The frozen harness and board source hashes match; reset controls are0 and eligibility checks recorded OUT6 state at the start and throughout each captured field. Only visible rows16–239 are examined, exactly as exported by harness line120. A positive witness requires nonblack observed PPM, RAM bit1 at that coordinate, and matching PROM RGB. Black PPM pixels are never treated as proof that raw video=0. End-of-field RAM may differ from pixel-time RAM, so this is a conservative intersection. Ineligible fields have no mask analysis, and zero counts represent empty coverage.

| Frame | Static0/flip0 | RGB-unequal visible pairs | Any lit | Both halves lit | O4-unequal pairs with lit |
|---:|:---:|---:|---:|---:|---:|
|1|True|106|0|0|0|
|2|True|106|0|0|0|
|3|True|106|0|0|0|
|4|True|106|0|0|0|
|60|False|excluded|0|0|0|
|68|False|excluded|0|0|0|

Reference-compatible frames1–4/60 contain0 lit observations in unequal RGB pairs, including0 with lit pixels in both halves. These frames supply no positive witness against masking; they do not qualify all frames.

Frame68 is retained only for same-side evidence after the known IRQ divergence. Even a both-halves witness does not settle physical capture phase, electrical propagation or source-board revision. No primitive test, broad simulation, production edit, origin shift or timing tuning was performed. Complete hashes/counts and recovery handles are in `docs/evidence/sheriff_color_clock_applicability.json`; producer `_checks/agent-color-applicability-20261010/analyze.py` performs this passive check.
