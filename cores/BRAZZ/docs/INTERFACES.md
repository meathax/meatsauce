# CrystalSystem board contracts

Game logic runs in the planned 85.90908 MHz domain. CPU architectural CE is every two cycles, pixel CE every twelve. Memory handshakes are sampled on every system edge, including while CPU retirement is paused. The MiSTer HPS/DDR port crosses domains through explicit request/response queues.

## Board transactions

`cs_bus_pkg` defines a 32-bit little-endian request: aligned **byte** address, write data, four byte strobes, write direction. `valid && ready` accepts once. The request remains stable while valid and not ready. Every accepted transaction, including a write, gets exactly one later response (`valid`, aligned-word data, error). There is no same-edge zero-latency response; the requester always captures completion. One outstanding transaction per client initially; response is not backpressured. Reset cancels all outstanding work on both sides and suppresses late responses.

Byte lane 0 is bits 7:0 at the aligned address; lane 3 is bits 31:24. Reads return the whole aligned word. CPU adapters shift/sign-extend subword reads and split accesses crossing words; SE3208 supports unaligned words, so a misaligned architectural access cannot become an address error. MMIO effects apply once to accepted valid lanes, regardless of wait duration.

`cs_bus_ram` is a synthesizable small RAM slave for local storage and protocol bring-up, with explicit latency. It is not the eventual 24 MiB external memory fabric. Reset preserves RAM; board power-on initialization/loading is separately owned. Out-of-range or unaligned **bus** requests respond with an error and never alter RAM.

## Shared external memory

Clients: CPU fetch/data, two DMA channels, GPU packet/texture/destination, scanout, audio, loader/debug. Each owns its request until accepted and waits for its response. Backend byte-address units are distinct from CPU map and DDR3 port units. The future arbiter reserves scanout/audio/refresh deadlines while guaranteeing CPU/DMA/GPU progress; counters expose service/wait/overrun conditions. CPU/DMA writes invalidate transparent prefetch/texture caches as appropriate. GPU blend reads observe prior pixel writes.

## CPU, output and state

CPU retirement emits PC-before, opcode, PC-after and architectural R0–R7/SR/SP/ER for differential checks. Interrupt entry is a separate event with acknowledged vector. Faults identify PC/opcode/address rather than silently executing placeholders. Pause stops new retirement but drains/captures outstanding memory replies. State access requires a declared quiescent boundary.

GPU output is native RGB565 converted to RGB888 plus H/V sync/blank and stable pixel CE. It uses the actual stored framebuffer, not an injected MAME image. SPU output is signed stereo with sample strobe and source-compatible IRQ status. Coin IRQs are edge events; other sources retain pending status until acknowledged.

Loading/reset owns memory before CPU start and installs BIOS/flash plus the documented protection overlay without changing source ZIPs. The initial per-game configuration selects only crysking.
