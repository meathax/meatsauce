# Source-bound RAM port candidate
The physical strip RAM has CPU read/write plus **the renderer's synchronous read**. System81/96 proves the apparently named debug_strip_data is the real scanline input. It cannot be removed. A same-clock true-dual-port memory can represent these ports only if both CPU and renderer old-data collisions, byte enables, initialization and one-clock latency are preserved.

Work RAM has mutually exclusive CPU/HLE versus acknowledged paused-hiscore service, but coin HLE branches board300/305 make **two different-address writes in one edge**. They also use the pre-edge high byte of work0x29 for the write to0x22. A single-write-port conversion is incorrect. Candidate: TDP portA normal service/0x29 write, portB the second0x22 write, with an exact8-bit shadow of0x29 high updated by every matching high-byte writer. The physical work debug output is unconsumed; simulation observation support must be explicit.

Do not insert an extra CPU pipeline or DTACK delay. The read/response selection must retain original accepted-edge behavior, AS and byte-strobe qualification, pause semantics and HLE side effects. Confirm actual M10K read-during-write policy; no dont-care collision waiver.

Work+strip contain98304bits. SoundROM adds524288bits; the sum622592 is only290 below the parent-reported board622882 registers. This is a useful arithmetic hypothesis, not final attribution: soundROM may dominate the resource problem and requires actual inference evidence. MainROM is already healthy and should remain untouched.

A narrow old/new storage contract should exercise both coin branches, byte lanes, old-data collisions, reset retention and paused hiscore. One subsequent bounded actual-fx68k prefix must compare unchanged bus ticks/data/DTACK and renderer output through those transactions before re-map. No RTL edit, replay or Quartus was performed in this review. All strict resource gates remain pending.
