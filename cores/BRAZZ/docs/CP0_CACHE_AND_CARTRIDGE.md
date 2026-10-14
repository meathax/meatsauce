# CP0 transport cache and cartridge commands

## Evidence and implementation scope

The production CPU executes the independently decoded SE3208 MVTC/MVFC instructions through `se3208_cp_access`. `vr0_cp0` now supplies a real cache/control endpoint rather than acknowledging these instructions without effects. It uses the qualified VISA2000 register profile from the ADChips data book, PDF pages 55–57. The related Jupiter data book establishes implicit R0 transfer semantics but has a different control-register map; that map is not used here. Document URLs, hashes, reviewed pages and conflicting claims are recorded in `se3208_databook_research.json` and `SE3208_CONTROL_INTERFACE.md`.

Neither book identifies the actual VRender0 revision on this PCB. VISA2000 describes a 2KiB cache while its status table describes 1KiB; Jupiter describes 4KiB. The current 4KiB geometry and VISA descriptor are explicit parameters, not proof of the physical configuration. No emulator or empty vendor simulator handler is used to establish cache effects.

| CP0 register | Implemented behavior |
|---|---|
| CR7 | Write bit 11 enables/disables the transport cache; read returns the qualified fixed master fields `0x1100`. |
| CR6 | Read-only qualified descriptor `0x80204b01`, with live enable bit 23 and invalidation-busy bit 20. |
| CR5 | Write bit 0 starts a real two-way tag sweep; zero has no action. Read returns zero. |
| CR3 | Qualified write-through mode and fixed read bit 7. A write requesting write-back, bit 6, returns an explicit error. |
| Other register / nonzero coprocessor | Explicit unsupported-device error. |

The default cache has 128 sets, two ways and 16-byte lines. A miss fetches four physical 32-bit words; hits use synchronous data RAM. Writes are serialized write-through with byte-lane updates on hit and no allocation on write miss. Failed hit writes invalidate the potentially changed line. Bypassed writes invalidate matching lines before cache re-enable. Completed DMA/GPU/SPU writes snoop matching CPU lines. A snoop during fill prevents a torn line from being installed; an already-read requested word can still be returned as that transaction's earlier snapshot. Cartridge bank/command changes trigger whole-cache invalidation. Control replies remain stable under backpressure and status can be read during the actual invalidation sweep.

The qualified descriptor advertises a four-word write buffer, but this implementation currently serializes writes. Write-buffer timing, physical cache geometry/revision, debug/privilege controls, write-back and the other coprocessor instruction classes remain unresolved. Functional game boot with this endpoint will not establish their physical fidelity.

## Architectural comparison with cache enabled

The board exposes CPU requests/replies before the cache. The independent CPU reference consumes those architectural accesses, not line-fill traffic or a guess about physical bus requests. MVTC payloads are checked against pre-instruction R0. MVFC values come from the observed device reply, like observed MMIO input values; the CP0 unit bench separately tests the qualified register/cache profile. Thus the boot comparison checks CPU semantics and access ordering, not an independently emulated physical CP0 implementation.

`scripts/sim.py cp0` passes 2,034 CPU accesses / 5,911 backend requests / 42,600 clocks: enable/status, lane writes, both ways/LRU, explicit and external/global invalidations, fill snoops, backend errors, request stalls and held control responses. Result: `simulation_cp0.json`.

The integrated `scripts/sim.py bios_sound` synthetic reset-vector BIOS enables the cache and stores the observed CR6 value `0x80a04b01` through CPU instructions. It passes 3,451 CPU comparisons, 3,438 cache hits / 36 misses, two CP transfers, 26 sound MMIO accesses, eight SPU reads, 24 independently checked stereo outputs and both real IRQ2 entries/returns. Scanout performs 1,760 reads without a deadline/error. This is diagnostic firmware, not original-game boot acceptance.

## Cartridge first-word command/query endpoint

`cs_flash_cmd` implements the pinned MAME 0.289 `crystal.cpp` behavior, lines 272–297, at the banked cartridge first word `0x05000000`:

| Low command byte | First-word read behavior |
|---|---|
| `0xff` (including reset) | Normal external banked ROM; absent banks read `0xffffffff`. |
| `0x90` | Present bank returns Intel 128Mbit identity `0x00180089`; absent bank returns `0xffffffff`. |
| Other | Zero. |

Writes replace the whole command word, matching MAME's assignment without `COMBINE_DATA`. The existing CPU bus has already positioned byte lanes before this endpoint. The 48MiB Crystal of Kings image has three present 16MiB banks; bank values 3–7 are absent. Normal ROM contents are still fetched from the genuine privately staged cartridge. Query reads/writes use a registered MMIO reply; they do not write into cartridge data. The first word is uncached, and all cartridge reads bypass caching outside normal command mode. Command/bank changes invalidate cached aliases.

`scripts/sim.py flash_cmd` passes all 2,048 command/bank combinations, full-word replacement, absent-bank identity, reset and normal-ROM selection in 6,146 clocks. Result: `simulation_flash_cmd.json`. This is the game's MAME-qualified query interface, not a complete NOR program/erase or electrical timing model. No invented erase/program success is returned.

## Interrupt-map compatibility hole

The first interrupt-controller word at 0x01800c00 has no handler in pinned crystal.cpp/vrender0.cpp. Native MAME boot capture observes zero at 02081e8a and 020115d4, followed by ignored writes of 0x1800/0x2000. vr0_control now handles only that specific word as zero-read/ignored-write; its real INTVEC/INTEN/INTST state remains separate, and unknown active-device addresses still error. The focused control bench verifies those accesses do not mutate IRQ state. This is MAME compatibility evidence, not identification of a physical interrupt mode register.

The original cold boot after the interrupt-map-hole change reached seven real CP transfers and enabled the cache: 10,881,052 independently compared instructions, 2,629,059 hits / 9,330 misses, 61,956 MMIO accesses. It reached game code 0x02070818 at the 250-million-clock probe limit without a missing-device/CPU instruction fault. This establishes original-program cache use with this qualified profile, not physical descriptor fidelity or attract/gameplay acceptance.

## Cache address policy regression

The first extended original boot stopped on a line-fill access to 0x0120000c. This was not a missing cabinet register: the CPU's actual cabinet read had been incorrectly considered cacheable by a broad address-less-than-0x01800000 test. The cache fetched four words across the I/O map and reached its unmapped fourth word. The policy now whitelists only the actual 128KiB BIOS range, main RAM and normal-mode cartridge ROM. Cabinet/SoC/video/sound registers bypass caching.

The integrated sound BIOS includes two real CPU system/DIP reads with the cache enabled. The bench changes DIP pins between them; RAM snapshots must be 0xffffffff then 0xffffff7f, and exactly two MMIO reads must occur. It passes alongside all existing audio/IRQ/scanout checks: 3,443 matched instructions, 3,428 hits / 38 misses. No fake 0x0120000c response was added to hide the invalid speculative access. The preceding 15,285,473-instruction boot stop and subsequent rebuilt run are distinguished in progress.md.

The corrected original boot reaches 23,530,913 matched CPU instructions at the 500-million-clock limit, with seven CP transfers and 18,296,977 cache hits. The invalid cabinet line fill is gone. It is still in game code (0x02085f96), with zero GPU packets; the limit result is exit 1 and is not a game acceptance pass.

## Main-RAM physical aliases

Work RAM's bit-23 mirror is now canonicalized before CPU cache lookup/backend requests and before external-write snoops. Architectural trace addresses stay unchanged. A real cache-enabled CPU test proves successive writes through 020.../028... views are visible through either alias, storing 12345678/CAFEBEEF/5A5AA5A5. The updated sound/IRQ/input/scanout diagnostic passes 4,779 comparisons with 4,764 hits / 44 misses. See CPU_FETCH_THROUGHPUT.md for source/coverage limits.

## Release gate

These changes unblock the original control-instruction stop and cartridge query accesses. Attract mode, gameplay, original audio, realistic SDRAM timing, exact physical CP0 configuration and the final simulation gate must still be established. No Quartus or RBF build is part of this work.
