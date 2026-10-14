# Conditional 4116 data ordering

An isolated synchronous storage model can reproduce source-declared pin events. CPU_WR_RD generation, physical row sampling and serializer electrical timing remain open. No production integration or physical pass follows.

[TI's 1982 MOS Memory Data Book](https://bitsavers.org/components/ti/_dataBooks/1982_LCC7061_TI_MOS_Memory_Data_Book.pdf), TMS4116NL, October1977/revisedMay1982, PDF pages26/27/30/31/32/33/34 (printed25/26/29/30/31/32/33), supplies the primary rules. RAS/CAS falling latch row/column. Early writes capture DI at CAS falling with WE already low; delayed writes capture DI at WE falling with CAS already low. DO is unlatched: after access it stays valid while CAS is low, then releases when CAS rises; early-write DO stays high impedance. RAS-only refresh covers128rows within2ms.

Grades15/20/25 give CAS-access maxima100/135/165ns and CAS-high output-disable ranges0–40/0–40/0–60ns, at CL100pF/twoSeries74TTLloads. RAS-access bounds require RAS→CAS no greater than50/65/85ns. Actual Sheriff's fitted vendor/grade/load and board delays are unknown.

Frozen video cycles give RAS→CAS8crystal periods=396.825397ns, CAS→candidate serializer clock4periods=198.412698ns, at20.16MHz. Therefore use CAS-relative access limits. Residual budgets are98.412698/63.412698/33.412698ns for additional path delay and setup; this is arithmetic, not closure.

At candidate loads156/188, RAS rises for either fixed CPU_WR_RD level. CAS also rises for CPU_WR_RD=0, while it stays low for CPU_WR_RD=1. The0ns disable minimum supplies no guaranteed post-CAS hold. A shared-clock functional abstraction samples old DO before counter-derived CAS changes update validity; actual electrical hold remains unqualified. Do not invent a four-clock data pipeline from the access maximum: a one-clock BRAM response can be held before the capture deadline.

Frozen CPU_WR_RD=0 rows140/172 have CAS falling while RAS stays high: no open row, hence no data transaction. Video rows then open144/176 while CAS rises; valid video CAS falls152/184. This finding uses retained rows, with no phase derivation rerun. Fixed branches do not resolve dynamic CPU_WR_RD changes.

The smallest conditional model uses one16KiB×8 single-port synchronous BRAM, row7/column7, row/column validity, read-response pending, heldDO/read-valid and previous pins. The caller supplies explicit7bit multiplexed address pins, RAS/CAS/WE and DI, using the master clock. The source-supported index is row|(column<<7); the module does not generate screen coordinates or arbitration.

Consumers use pre-edge DO/read-valid. A valid CAS fall latches current column pins with the stored row and either stores early-write DI once or requests a synchronous read. A later WE fall uses the latched column only while RAS/CAS are low with a valid row/column transaction. CAS rise cancels pending output and releases read-valid after consumers have sampled old state. RAS rise closes the row without independently erasing already valid DO while CAS stays low. A new row invalidates its predecessor's column. Do not turn a level predicate, CAS rise, an orphan CAS fall or stale column into a write.

Implementation must expose or reject RAS/CAS simultaneous falls and unresolved WE/CAS same-edge ordering rather than inventing an electrical sequence. BRAM read payload is a functional response; it does not certify analog access delay.

Remaining integration conditions: CPU_WR_RD source/polarity; CPU address/WR/DI setup/hold and READY/readback; row capture around counter transitions; serializer load/shift and electrical setup/hold; exact Sheriff revision/vendor/grade/load; reset/refresh and master-edge alignment. The isolated model can qualify event semantics independently of those inputs.
