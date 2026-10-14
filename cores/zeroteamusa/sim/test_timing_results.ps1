$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/timing_results.ps1')
$testRoot = Join-Path $PSScriptRoot ('results/timing-gate-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$models = @([pscustomobject]@{corner='slow'; model='slow'; voltage_mv=1100; temperature_c=100},
            [pscustomobject]@{corner='fast'; model='fast'; voltage_mv=1100; temperature_c=0})
$rows = @(foreach ($model in $models) {
    foreach ($type in @('setup','hold','recovery','removal','pulse_width')) {
        [pscustomobject]@{corner=$model.corner; analysis=$type; slack_ns='0.250'; from='source'; to='destination'}
    }
})
$coverage = @('Illegal Clocks','Unconstrained Clocks','Unconstrained Input Ports',
    'Unconstrained Input Port Paths','Unconstrained Output Ports','Unconstrained Output Port Paths') |
    ForEach-Object { "; $_ ; 0 ; 0 ;" }
function Write-Fixture {
    $models | Export-Csv "$testRoot/models.tsv" -Delimiter "`t" -NoTypeInformation
    $rows | Export-Csv "$testRoot/slacks.tsv" -Delimiter "`t" -NoTypeInformation
    $coverage | Set-Content "$testRoot/unconstrained.rpt"
    foreach ($model in $models) {
        @('loops','latches','pll_cross_check','no_clock','multiple_clock',
            'generated_clock','uncertainty','partial_multicycle','multicycle_consistency',
            'partial_min_max_delay','io_min_max_delay_consistency','no_input_delay',
            'no_output_delay','partial_input_delay','partial_output_delay') |
            ForEach-Object { "; $_ ; 0 ;" } | Set-Content "$testRoot/$($model.corner)_constraints.rpt"
    }
}
$checks = 0
function Assert-Rejected([string]$Name) {
    $rejected = $false
    try { $null = Read-TimingAudit $testRoot } catch { $rejected = $true }
    if (!$rejected) { throw "Timing gate incorrectly accepted $Name" }
    $script:checks++
}
Write-Fixture
$null = Read-TimingAudit $testRoot
$checks++
Add-Content "$testRoot/slow_constraints.rpt" '; uncertainty ; 1 ;'
Assert-Rejected 'missing clock uncertainty'
Write-Fixture
Add-Content "$testRoot/slow_constraints.rpt" '; no_clock ; 1 ;'
Add-Content "$testRoot/slow_constraints.rpt" '; emu:emu|cpu|pc[0] ; No clock feeds this register''s clock port. ;'
Assert-Rejected 'unclocked fabric register'
Write-Fixture
$null = Read-TimingAudit $testRoot
$checks++
$rows[-1].slack_ns = '-0.001'; Write-Fixture; Assert-Rejected 'fast-corner pulse violation'
$rows[-1].slack_ns = 'NaN'; Write-Fixture; Assert-Rejected 'non-finite slack'
$rows[-1].slack_ns = '0.250'
Write-Fixture
$rows[0..8] | Export-Csv "$testRoot/slacks.tsv" -Delimiter "`t" -NoTypeInformation
Assert-Rejected 'incomplete analysis inventory'
$rows[0].analysis = 'hold'; Write-Fixture; Assert-Rejected 'duplicate analysis'
$rows[0].analysis = 'setup'
$rows[0].corner = 'unknown'; Write-Fixture; Assert-Rejected 'unknown corner'
$rows[0].corner = 'slow'
Write-Fixture
@($models[0],$models[0]) | Export-Csv "$testRoot/models.tsv" -Delimiter "`t" -NoTypeInformation
Assert-Rejected 'duplicate corner'
Write-Fixture
$coverage -replace 'Unconstrained Input Port Paths ; 0 ; 0', 'Unconstrained Input Port Paths ; 0 ; 1' |
    Set-Content "$testRoot/unconstrained.rpt"
Assert-Rejected 'hold-only uncovered input path'
Write-Fixture
$coverage[0..4] | Set-Content "$testRoot/unconstrained.rpt"
Assert-Rejected 'missing coverage summary'
Write-Fixture
$null = Read-TimingAudit $testRoot
$checks++
Write-Output "Timing gate regression PASS ($checks checks)"
