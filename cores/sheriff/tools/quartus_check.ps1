param(
    [ValidateSet('Fit')][string]$Stage = 'Fit',
    [string]$QuartusBin = 'D:\q17\quartus\bin64',
    [string]$Queue = 'D:\vibes\fpga\bin\quartus-safe.ps1',
    [string]$ProjectRoot = '',
    [switch]$SnapshotOnly
)
$ErrorActionPreference = 'Stop'
if (-not $SnapshotOnly) {
    throw 'No admitted Sheriff preassembly recipe is configured. Prepare sources with prepare_timing_snapshot.ps1; register an independent complete-job recipe before compiler execution.'
}
& (Join-Path $PSScriptRoot 'prepare_timing_snapshot.ps1') -ProjectRoot $ProjectRoot -QuartusBin $QuartusBin -Queue $Queue
# All compiler execution remains with the canonical shared queue; no raw
# compiler, full-flow build, assembler, conversion or deployment is invoked.
