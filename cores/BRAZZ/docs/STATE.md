# State inventory

No game RTL state implemented yet. Reserve debug/state access as blocks are created: CPU R0–R7/PC/SR/SP/ER/IRQ state; SoC register/IRQ/DMA/timer/UART/GPIO state; RAM/NVRAM/RTC; video queue/render/palette/bank/flip state; audio voices/control/phase/envelopes; memory arbitration/cache validity; loader/reset/ROM identity.

State ports support deterministic debugging/checkpoints. Shipping user savestates is optional and is not a bring-up prerequisite. Do not dump a partial cache/pipeline checkpoint as if it were a complete resumable board state.
