# SE3208 fetch-launch throughput change

The natural original-ROM activity log identifies CPU dispatch overhead as a real bottleneck: in cached initialization windows, instruction cost is about 18.8–20.5 system clocks while accepted CPU-request-to-reply waits occupy only 26–30% of system clocks. CPU CE remains the unchanged divide-by-two of the 85.90908MHz board clock. No instruction skip, idle-loop substitution or hidden clock overdrive is used.

Previously a completed instruction retired, entered FETCH_START to set its address, then entered ACCESS_START to launch the memory command. The CPU now launches the real next halfword fetch at the non-interrupt retirement boundary. Reset/state-load fallback launches directly from FETCH_START. The same bus adapter still holds requests and results under backpressure. A shared retire_interrupt predicate prevents any next fetch at a boundary owned by IRQ/NMI entry; stack/vector transfers and post-vector retirement keep their existing order.

Architectural state, opcode coverage and device semantics are unchanged. This is one dispatch optimization, not proof that final game throughput meets native speed. Further prefetch/pipeline/cache/transport work must follow measured game behavior and the realistic-memory gate.

| Independent regression | Prior clocks (2c4db42) | Current clocks | Coverage |
|---|---:|---:|---|
| CPU | 5,256,842 | 4,778,800 | 239,536 comparisons, 62,048 encodings, 1,210 IRQ/NMI cases, delays/backpressure/unaligned accesses/faults |
| Primary CP transport | 10,778 | 9,665 | 128 successful + 64 error cases, all 64 canonical transfers, paused CE/reset/held requests and replies |

The CPU unit bench starts many isolated state-loaded cases, so this clock reduction is not a gameplay FPS measurement. Existing unresolved encodings remain excluded there; primary transfer coverage remains separate. Reports: simulation_cpu.json and simulation_cpu_control.json.

The continuous production-board synthetic sound BIOS first passed 4,605 CPU comparisons, both real IRQ2 entries/returns, all 24 independently checked stereo outputs, live DIP reads and scanout. After the RAM-mirror regression below, it passes 4,779 comparisons with the same sound/input/IRQ acceptance. Higher retirement count over this diagnostic does not establish original-game speed.

## Main-RAM mirror coherence

Pinned crystal.cpp maps 8MiB work RAM at 02000000–027FFFFF and mirrors it with address bit 23. The board now clears that mirror bit before CPU cache lookup/physical requests and before completed external-write snoops. CPU architectural traces retain their original requested addresses. Both 020... and 028... views therefore share physical cache tags and write visibility instead of allocating incoherent aliases.

The real CPU diagnostic writes and reads through both views with caching enabled. Stored snapshots must be 12345678, CAFEBEEF and 5A5AA5A5 as successive writes through either alias change the shared word. The changed board test passes 4,779 matched CPU instructions; 4,764 cache hits / 44 misses; both live DIP snapshots; 26 sound MMIO accesses; eight SPU reads; all 24 audio frames; both sound interrupts; 1,760 scanout reads with no audio/video faults or missed deadlines. External alias snoops use the same canonical address rule; full multi-client/realistic-memory stress remains part of the final gate.

## Original boot qualification

The natural original-ROM run with pre-optimization CPU/board sources from observer commit 17db9cf (same CPU as 2c4db42) completed its first drawing packet at 1,905,049,721 clocks / 98,334,328 matched instructions. Its source-qualified baseline is preserved separately.

The fetch-launch/RAM-alias revision then reached the first drawing packet at 1,517,618,206 clocks / 98,670,053 matched instructions, about 20.34% fewer total clocks. Both runs perform 482 stores. The later packet's exact ordered stores and full framebuffer independently match MAME against its actual pre-draw RAM. Changed IRQ scheduling/instruction counts mean this is an observed boot comparison, not an identical-instruction-count or gameplay-speed benchmark. The extended revision subsequently reaches 204,454,566 matched instructions / 2,205 GPU packets in its three-billion-clock window and renders Insert Coin prompts. `CPU_BUS_RESPONSE.md` describes the later response-stage optimization separately.

The original MAME interpreter decrements its abstract instruction budget once per instruction (`se3208.cpp execute_run`); this is useful for estimating initialization windows, not a physical instruction timing specification. Native first active submission is frame 154. Stable attract/gameplay/original audio, realistic-memory performance and the final simulation gate remain required. No FPGA/RBF work was performed.
