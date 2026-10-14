## 2026-10-09 — Qualify FX68K write commits with byte strobes
- Context: Bringing up Kyros with pinned fx68k 0602ee4627b10f301298f2673d826cdd6baa9327, 48 MHz master enables and Verilator 5.050.
- Symptoms: Reset vectors and MCU ID worked, but the 90-frame run remained near ROM 0x01fc00 with only five work writes, no strip writes and no main IRQ acknowledgements.
- Verified cause: The adapter accepted AS before write UDSn/LDSn became active. Its bounded trace showed stack writes with both strobes high; the return address 0x0422 was discarded and subsequent stack reads returned zero.
- Fix: Commit/acknowledge a normal bus transaction only when AS is active and either byte strobe is active; keep autovector interrupt acknowledgement separate. Preserve one-commit-per-transaction behavior.
- Check: The real-ROM regression wrote/read 0x0422 with both word strobes active. The corrected 90-frame run produced 32234 strip writes, 35 IRQ1 and 35 IRQ2 acknowledgements and zero unmapped accesses. This proves the bus/boot boundary, not graphics, fitted timing or release readiness.
- Evidence/recovery: D:\Arcade\AI\aCORES\Alpha68k N local develop commit 01a1aa1; research/cpu_boot_regression.json; sim/captures/rtl/kyros_cpu10_bus (failure), kyros_cpu10_strobes (fix), kyros_cpu90_strobes; progress.md. Large captures remain local and ignored.
