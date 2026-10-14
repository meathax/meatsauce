# Japan720 compiled-source scope

Preserved ELF 54529234af5aa50cb1d486d8f037a7dd8496b0da0f83e399b0cf8eb2094498cf matches the actual completed Japan720 exit receipt. All65 actual compiled HDL source snapshots match their original manifest pins. Current differences are explicitly classified in the JSON.

The only semantic compiled HDL change is background initialization/retention across warmreset; original720 captured fields/audio use cold/download reset only; its terminal heldreset follows capturedPCM/frame output. System CRLF and JT49 whitespace differences do not alter the normalized source. CRT/PLL are inventoried but absent from the actual compiled native source inventory. No CPU/clock/ROM-handshake/sound change was identified.

No Japan720 replay is required by these identified HDL changes. Host adds optionalreset/probes and conditionalSDRAM re-eval; it is not byte-identical or solelylogging. This analysis does not promote broad host/runtime/hardware equivalence or Japan death/reset/effects. Preserve fulltap720 finite sound data pass and remaining action gaps.
