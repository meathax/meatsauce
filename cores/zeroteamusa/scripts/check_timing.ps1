param(
    [ValidateSet('Synthesis', 'Fit', 'STA', 'All')]
    [string]$Stage = 'All',
    [string]$QuartusBin = 'D:\q17\quartus\bin64',
    [string]$ConstraintOverlay = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'timing_results.ps1')
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
$timingLock = $null
try {
    $logRoot = Join-Path $projectRoot 'sim/results/timing'
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    try {
        $timingLock = [IO.File]::Open((Join-Path $logRoot 'timing.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw 'Another ZeroTeam timing workflow owns the project database. Wait for its terminal result before starting another run.'
    }
    # Explicit stages intentionally exclude the assembler and RBF generation.
    throw 'Standalone Quartus stages are disabled. Use canonical quartus_flow.ps1 -Action Start -RecipeId zero-complete-current-source-preassembly after the complete recipe is registered. Assembly authority remains separate.'
    $stages = switch ($Stage) {
        'Synthesis' { @('map') }
        'Fit' { @('fit', 'sta') }
        'STA' { @('sta') }
        'All' { @('map', 'fit', 'sta') }
    }
    if ($stages -contains 'map') {
        & "$QuartusBin\quartus_sh.exe" -t sys/build_id.tcl pre_flow ZeroTeam ZeroTeam *> "$logRoot/build-id.log"
        if ($LASTEXITCODE -ne 0) { throw "Build ID generation failed; see $logRoot/build-id.log" }
    }
    function Get-SourceIdentity {
        $sourcePaths = @(Get-ChildItem rtl, sys -Recurse -File | Where-Object {
            $_.Extension -in '.v', '.sv', '.svh', '.vhd', '.qip', '.sdc', '.tcl', '.hex', '.mif', '.mem'
        }) + @(Get-Item ZeroTeam.sv, ZeroTeam.qpf, ZeroTeam.qsf, ZeroTeam.sdc, files.qip, build_id.v,
            scripts/timing_audit.tcl, scripts/timing_results.ps1, scripts/check_timing.ps1)
        if ($ConstraintOverlay) { $sourcePaths += Get-Item -LiteralPath $ConstraintOverlay }
        @($sourcePaths | Sort-Object FullName | ForEach-Object {
            [ordered]@{path=$_.FullName.Substring($projectRoot.Length + 1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        })
    }
    $sourceIdentity = @(Get-SourceIdentity)
    $fullIdentity = ($sourceIdentity | ConvertTo-Json -Depth 5 -Compress).Trim()
    function Assert-CurrentSources {
        $currentIdentity = (@(Get-SourceIdentity) | ConvertTo-Json -Depth 5 -Compress).Trim()
        if ($currentIdentity -ne $fullIdentity) {
            throw 'Timing inputs changed during this workflow. No changed-source stage is authorized; restart the necessary compilation stages.'
        }
    }
    $sourceIdentity | ConvertTo-Json -Depth 5 | Set-Content "$logRoot/source-identity.json" -Encoding UTF8
    # Constraint-only STA reruns may reuse placement, but never changed RTL.
    $logicIdentity = ($sourceIdentity | Where-Object {
        $_.path -notmatch '\.sdc$' -and $_.path -notmatch '^scripts/(timing_audit\.tcl|timing_results\.ps1|check_timing\.ps1)$'
    } | ConvertTo-Json -Depth 5 -Compress).Trim()
    # Invalidate any prior passing status before running stages for new sources.
    [ordered]@{
        status='Pending requested Quartus stages'
        closure_established=$false
        source_identity=$sourceIdentity
    } | ConvertTo-Json -Depth 6 | Set-Content "$logRoot/timing-status.json" -Encoding UTF8
    function Assert-SourceIdentity([string]$RequiredStage) {
        $identityFile = "$logRoot/$RequiredStage-source.json"
        if (!(Test-Path -LiteralPath $identityFile) -or
            (Get-Content -LiteralPath $identityFile -Raw).Trim() -ne $logicIdentity) {
            throw "Missing or stale $RequiredStage netlist. Run the required preceding stages for the current RTL first."
        }
    }
    foreach ($step in $stages) {
        Assert-CurrentSources
        if ($step -eq 'fit') { Assert-SourceIdentity 'map' }
        if ($step -eq 'sta') { Assert-SourceIdentity 'fit' }
        # A failed in-place stage must not leave an older identity authorizing
        # reuse of a possibly incomplete database.
        $invalidated = switch ($step) {
            'map' { @('map', 'fit', 'sta') }
            'fit' { @('fit', 'sta') }
            'sta' { @('sta') }
        }
        foreach ($oldStage in $invalidated) {
            Remove-Item -LiteralPath "$logRoot/$oldStage-source.json" -ErrorAction SilentlyContinue
        }
        $log = "$logRoot/$step-current.log"
        Write-Output "Starting Quartus $step (no assembler/RBF)"
        # Quartus 17 STA does not accept the map/fit settings-write switches.
        $settingsArgs = if ($step -eq 'sta') { @() } else { @('--read_settings_files=on', '--write_settings_files=off') }
        if ($step -eq 'sta') {
            $auditRoot = Join-Path $logRoot ('audit-' + [Guid]::NewGuid().ToString('N'))
            [string[]]$overlayArgs = @(if ($ConstraintOverlay) { $ConstraintOverlay })
            & "$QuartusBin/quartus_sta.exe" -t scripts/timing_audit.tcl ZeroTeam $auditRoot @overlayArgs *> $log
        } else {
            & "$QuartusBin/quartus_$step.exe" @settingsArgs ZeroTeam -c ZeroTeam *> $log
        }
        $stageCode = $LASTEXITCODE
        Get-Content -LiteralPath $log -Tail 24
        if ($stageCode -ne 0) { throw "Quartus $step failed with exit $stageCode; see $log" }
        if (Select-String -LiteralPath $log -Pattern 'Warning \(332088\)' -Quiet) {
            throw "Generated clock source has no physical path to its target; see $log"
        }
        Assert-CurrentSources
        if (Select-String -LiteralPath $log -Pattern 'Critical Warning.*Ignored assignment (INPUT_REGISTER|OUTPUT_REGISTER)' -Quiet) {
            throw "Quartus $step ignored an I/O register assignment. Correct its QSF node name before accepting this stage; see $log"
        }
        $logicIdentity | Set-Content "$logRoot/$step-source.json" -Encoding UTF8
        if ($step -eq 'sta') {
            $audit = Read-TimingAudit $auditRoot
            [ordered]@{
                status='PASS: all device corners and five timing analyses; no uncovered paths'
                constraint_review_required=$true
                source_identity=$sourceIdentity
                closure_established=$false
                audit_directory=$auditRoot
                audit_script_sha256=(Get-FileHash scripts/timing_audit.tcl -Algorithm SHA256).Hash
                corners=$audit.corners
                results=$audit.results
                unconstrained_setup_and_hold_counts=$audit.unconstrained_setup_and_hold_counts
                hps_model_review=$audit.hps_model_review
            } | ConvertTo-Json -Depth 6 | Set-Content "$logRoot/timing-status.json" -Encoding UTF8
        }
    }
    Write-Output 'Requested stages finished without reported slack violations. Review path coverage and constraint justification before declaring timing closed.'
} finally {
    if ($null -ne $timingLock) { $timingLock.Dispose() }
    Pop-Location
}
