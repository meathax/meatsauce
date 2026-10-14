# Private Super Stingray P6 candidate

The overlay adds the already proven real8748 wrapper and T48 closure to profile2, with the existing655360-byte loader/profile header and clean1024-byte d8748 firmware. All canonical sources remain untouched. The privatepatch changes only board, QIP, nativehost profile guard and nativebuild source closure; no build or simulation is launched.

All logic uses the48MHz master. Z80 uses fractional3579545Hz enables; MCU uses the unchanged9263750Hz wrapper oscillator and donor internal divide3/five-state execution. No extra divide15 or generated CPU clock is introduced. The MCU command lane is LDS only at080000..0801ff; wordindex/data/readmode are latched on actual accepted transactions.

A real MCU shared_write owns the existing low-byte RAM write port for that edge. A colliding profile2CPU work transfer waits; MCUword22 routes its externalregister, all highbytes and word29highshadow remain intact. Pause holds the HS borrow for three master edges while the registered MCU control/write pipeline drains; a shared_write also directly excludes HS service. This ordering remains to be observed in the coupled run. Physical collision priority remains unqualified.

Firmware IRQ2 is held untilIACK and replaces periodicKyrosIRQ2 for profile2. Freshrequest wins a sameedgeIACK; that boundary needs reference proof. MCUcontrol drivesflip. The pinnedfx68k HALTn is labelled single-step, so the candidate keeps it high and drains the acceptedAS cycle before freezing the existingphase/enables atAS-high while MCUHALT remainsasserted. This candidate HALT/DTACK cutoff needs a coupledCPU/pairedMAME trace and is not declaredcorrect.

Profile2sound uses ROM0000..7fff,RAM8000..87ff,latchc100,clearc102,DACc104. Existing nativeI/Ochips, mixerprofile, renderer and physicalstripread remain intact. Nativehost permitsprofile2 only with actualrecordedMAME controls/DIPs/coins; no KyrosdefaultDIP or syntheticgameplay fallback is allowed. Retainedreferencemetadata must be qualified before running.

Staticloader/sourcepins and patchchecks pass only; there is no HDLcompile, realStingrayCPU run, fullgraphics/audio, fit/timing or physicalMCU pass. Review integration_contract.json for exactpins, all open ordering assumptions and the minimum next acceptance steps.
