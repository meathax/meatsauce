Actual native61 build/run/verifier exited0, with all13 source/fidelity checks true and all61 CPU/renderer rows plus19whole RGB images exact. No production RTL or clocks changed.

Original irq1 tick47849465 is native field58; offsets {"intPend_rise": 20, "rInterrupt_capture": 32, "interrupt_sequence_entry": 40, "IACK_bus_attribute_rise": 144, "Iac_signal_rise": 136}.

Original irq2 tick48000000 is native field59; offsets {"intPend_rise": 21, "rInterrupt_capture": 41, "interrupt_sequence_entry": 49, "IACK_bus_attribute_rise": 153, "Iac_signal_rise": 145}.

The original collector-scope failure, frame-label-selected extraction, and earlier attribute-edge label are retained. Exact original ticks select the cases; no frames or pixels are shifted. Direct Iac and bus attribute edges remain distinct. Runtime MAME pending/next state at its IR-to-IRD cutoff is still missing. No physical cause, CPU correction, B16 closure or full graphics acceptance is proved.
