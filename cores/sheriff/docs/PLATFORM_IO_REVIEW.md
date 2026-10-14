# Frozen 66f53ed9 platform I/O review

The retained `66f53ed9` TimeQuest evidence contains **no unexplained unconstrained synchronous Sheriff CPU/RAM/video path**. The 4 input endpoints / 14 paths and 50 output endpoints / 98 paths are external `sys_top` ports with source-supported roles. All 12 reported clock targets are constrained. This satisfies the requirement to explain the reported unconstrained board paths; it does not require inventing external delays for interfaces without a synchronous receiver.

This review uses `_checks/agent-platform-check-66f53ed9-20261010/source`, its original archive (`5b9201d62084405818a69579f1404373ae3c5c83f2313b832ecd3a2151680dfc`), and the original timing report. It does not substitute current RTL or the legacy workspace alias. The independent source-only audit verifies the selected frozen source hashes and quoted lines against the original manifest, every setup/hold path row against the structured report, and identical unconstrained reports in all eight corners. See `docs/evidence/sheriff_platform_io_review_66f53ed9.json` and `_checks/agent-platform-io-review-66f53ed9-20261010/independent-verification.json`. No STA, compiler, native simulation, RTL or constraint change was performed.

## What the raw report establishes

`unconstrained-current.txt:9` reports zero illegal/unconstrained clocks. Lines 22–33 enumerate constrained fabric, game, HDMI, audio and hard-interface clocks. Input rows 112–125 comprise one HPS I2C input, one HPS interrupt input, six expander SDA captures and six direct card-detect-to-output mode-control paths. None terminates in a Sheriff board register. Output rows 133–230 all terminate in top-level ports; a game PLL forwarding its clock to `HDMI_TX_CLK` is an external clock path, not an unconstrained CPU/RAM register path. Setup and hold repeat the same sets. Six direct card-detect paths appear in both input and output tables; they are counted within each table rather than treated as additional internal paths.

| Source-supported role | Input paths | Output paths | Remaining interface requirement |
| --- | ---: | ---: | --- |
| HDMI clock and RGB/HS/VS/DE | 0 | 29 | Receiver setup/hold, forwarded-clock relationship and PCB clock/data skew for scaled and direct-video modes. |
| HDMI I2S/MCLK and USER_IO I2S aliases | 0 | 7 | Receiver clock/data requirements, board delay and open-drain/pullup behavior in the selected audio mode. |
| Expander I2C SDA and SCL/SDA outputs | 6 | 3 | Protocol sampling aperture, device response/hold times, pullup rise/fall and board delay. |
| HPS HDMI I2C | 1 | 2 | Vendor hard-IP I2C boundary and electrical/protocol contract. |
| HPS HDMI interrupt | 1 | 0 | Hard-IP input synchronization/metastability and interrupt handling contract. |
| Card-detect mode control | 6 | 6 | Static-use or safe mode-change/glitch contract; review each shared-pin mode separately. |
| Analog video and composite-sync aliases | 0 | 31 | Analog settling, channel/sync skew and receiver/hardware evidence; SD/SPI mode has a separate clocked interface contract. |
| SPDIF alias | 0 | 1 | Encoded-rate/jitter, electrical and shared-pin mode evidence. |
| Human LED status | 0 | 19 | Documented status-display exception candidate; no source-defined synchronous external receiver. |

Counts are path counts, not distinct pins or additional failures. No exception is approved by this review.

## Where real timing constraints apply

Frozen `sys/sys_top.v:1304` clocks HDMI output registers with `hdmi_tx_clk`; lines 1317–1337 select and drive video signals. Their external setup/hold budget is real. It must use the receiver's capture edge and both active clock modes, including forwarded-clock and board skew. A fabricated delay chosen to make the report empty would provide no evidence. Audio is similarly clocked by the audio PLL (`sys/sys_top.v:1569`, `:1583`); `USER_IO[2,4,5]` carry switched open-drain I2S signals at lines 1663–1666, not generic debug GPIO in these rows. The receiver and electrical configuration determine the appropriate constraints.

The expander is also a real sampled interface, despite its low speed. `sys/mcp23009.sv:27` instantiates the I2C engine at 500 kHz, while `sys/i2c.v:59` executes in the 50 MHz fabric clock. Lines 82–98 gate SDA capture on the internally generated I2C transition; lines 40–41 implement open-drain outputs. It needs an analysis tied to that protocol sampling window and real SDA/pullup/device timing. Low speed alone justifies neither a false path nor an arbitrary 20 ns input delay. The retained sources establish the sampling mechanism, not the external budget.

`HDMI_I2C_SDA` ends at a hard HPS peripheral boundary (`sys/sys_top.v:1133`), and `HDMI_TX_INT` enters HPS general-purpose input routing (`:234`). Empty clock fields on those TimeQuest rows are not evidence of a missing Sheriff clock. They require the vendor hard-IP contract and appropriate asynchronous-input handling evidence; assigning them a game-clock input delay would not prove that contract.

Card detect controls shared SD/analog routing at `sys/sys_top.v:131`–`:137`. The six direct input-to-output paths have no capture clock. They need a static/mode-change contract rather than a fictitious synchronous receiver. Analog video low bits and composite sync need settling/skew/receiver evidence; when the same pins carry SD/SPI, their actual card/interface clock and timing requirements apply instead. SPDIF needs its encoded serial timing/electrical contract. LEDs have no source-defined clocked external receiver and can be documented as status outputs without manufacturing a synchronous output delay.

## Limits and integration decision

The requirement **“no unexplained unconstrained board paths” is met for this frozen reported path set**. External synchronous HDMI/audio and sampled expander interfaces remain unqualified until their real budgets are supplied. Asynchronous, hard-IP, analog and status roles require their appropriate contracts or justified exceptions, not blanket false paths. This conclusion agrees with `PLATFORM_ACCEPTANCE.md:33`; its open platform-interface audit is distinct from an unexplained Sheriff internal endpoint.

The frozen `Nintendo8080.sdc` derives PLL clocks and uncertainty. `sys/sys_top.sdc:13`–`:22` already separates clock groups, and lines 24–77 contain existing platform exceptions. A zero unconstrained-clock count and this port classification do not independently prove every inherited CDC/exception safe. This review does not approve those exceptions or claim complete CDC/release qualification. No board-wide false path was added or proposed.

The separate retained cold-corner scaler setup failure of −0.008 ns remains a real internal timed-path failure. Explaining these external rows neither fixes that failure nor turns the baseline into a full timing/release pass. Future production DRAM integration also requires its own current-source timing review; isolated RAM evidence is not part of this frozen fit.
