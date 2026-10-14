# Private real-CPU interrupt recognition, finite 61-field replay

Actual simulation PID 80873 exited 0. All 19 RGB images and complete input, frame, instruction, bus and existing E/latch traces are byte-identical to the frozen replay. All 4745 recorded transitions satisfy the exact source rules, with zero violations. No production RTL, CPU state, clock, phase or input changes.

The first verifier coverage predicate matched frame labels without pairing assertion and IACK ticks. Its receipt is preserved. The paired timeline supersedes that coverage claim: IRQ1 assertion and IACK cross field boundaries. The finite final assertion is explicitly pending when its acknowledgement lies beyond the stop.

| Assertion field / IRQ | Assertion tick | rIpl tick | iIpl tick | pending tick | inl tick | IACK tick |
|---|---:|---:|---:|---:|---:|---:|
| 58 / irq2 | 47200000 | 47200005 | 47200013 | 47200021 | 47200049 | 47200169 |
| 58 / irq1 | 47849465 | 47849469 | 47849477 | 47849485 | 47849489 | 47849609 |
| 59 / irq2 | 48000000 | 48000005 | 48000013 | 48000021 | 48000033 | 48000153 |
| 59 / irq1 | 48660473 | 48660477 | 48660485 | 48660493 | 48660513 | 48660665 |
| 60 / irq2 | 48800000 | 48800005 | 48800013 | 48800021 | 48800161 | 48800313 |
| 60 / irq1 | 49471481 | unobserved | unobserved | unobserved | unobserved | outside finite stop |

The JSON links the two known field59 relocated tile writes to actual recognition and IACK ticks. PC values are internal observed state; they are not independent dispatch timestamps. B16, physical-cause and timing-fix acceptance remain false.
