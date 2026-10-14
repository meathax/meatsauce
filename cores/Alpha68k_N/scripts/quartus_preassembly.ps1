param([switch]$QueuedRecipeBody)
$ErrorActionPreference = 'Stop'
throw 'The obsolete leased/raw-shell preassembly recipe is retired. Review the immutable check project and Template build-ID/microcode prerequisites in docs/LOADER_AND_CLOCKS.md, then use C:\Users\meath\QuartusFast\quartus-fast.ps1 build --project PATH.qpf without --allow-rbf. Check-only map/fit/STA is unqueued; full compile/assembly remains gated and queued.'
