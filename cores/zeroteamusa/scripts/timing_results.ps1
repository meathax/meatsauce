function Read-TimingAudit([string]$AuditRoot) {
    $models = @(Import-Csv -LiteralPath (Join-Path $AuditRoot 'models.tsv') -Delimiter "`t")
    $results = @(Import-Csv -LiteralPath (Join-Path $AuditRoot 'slacks.tsv') -Delimiter "`t")
    $types = @('setup', 'hold', 'recovery', 'removal', 'pulse_width')
    if ($models.Count -eq 0 -or @($models.corner | Sort-Object -Unique).Count -ne $models.Count) {
        throw 'Missing or duplicated device operating conditions.'
    }
    if ($results.Count -ne 5 * $models.Count) { throw 'Incomplete multicorner timing results.' }
    foreach ($model in $models) {
        $rows = @($results | Where-Object corner -eq $model.corner)
        if ($rows.Count -ne 5 -or (Compare-Object ($rows.analysis | Sort-Object) ($types | Sort-Object))) {
            throw "Missing or duplicated timing analyses for $($model.corner)."
        }
    }
    foreach ($row in $results) {
        $slack = [double]::Parse($row.slack_ns, [Globalization.CultureInfo]::InvariantCulture)
        if ([double]::IsNaN($slack) -or [double]::IsInfinity($slack) -or $slack -lt 0) {
            throw "Timing FAILED: $($row.corner) $($row.analysis), slack $($row.slack_ns) ns."
        }
    }
    $coverage = Get-Content -LiteralPath (Join-Path $AuditRoot 'unconstrained.rpt') -Raw
    $counts = [regex]::Matches($coverage, '(?m)^\s*;\s*(Illegal Clocks|Unconstrained (?:Clocks|Input Ports|Input Port Paths|Output Ports|Output Port Paths))\s*;\s*(\d+)\s*;\s*(\d+)\s*;')
    if ($counts.Count -ne 6) { throw 'Missing or unreadable unconstrained-path summary.' }
    foreach ($count in $counts) {
        if ([int]$count.Groups[2].Value -ne 0 -or [int]$count.Groups[3].Value -ne 0) {
            throw "Incomplete timing coverage: $($count.Groups[1].Value)."
        }
    }
    $hpsModels = @()
    $zeroChecks = @('loops','latches','pll_cross_check','generated_clock','uncertainty',
        'partial_multicycle','multicycle_consistency','partial_min_max_delay',
        'io_min_max_delay_consistency','partial_input_delay','partial_output_delay')
    foreach ($model in $models) {
        $tag = $model.corner -replace '[^a-zA-Z0-9_.-]', '_'
        $checks = Get-Content -LiteralPath (Join-Path $AuditRoot ($tag + '_constraints.rpt')) -Raw
        $summary = @{}
        foreach ($match in [regex]::Matches($checks, '(?m)^;\s*([a-z_]+)\s*;\s*(\d+)\s*;')) {
            $summary[$match.Groups[1].Value] = [int]$match.Groups[2].Value
        }
        foreach ($check in $zeroChecks) {
            if (!$summary.ContainsKey($check) -or $summary[$check] -ne 0) {
                throw "Invalid or missing $check constraints at $($model.corner)."
            }
        }
        if (!$summary.ContainsKey('no_clock')) {throw 'Missing no-clock audit.'}
        $unclocked = [regex]::Matches($checks, '(?m)^;\s*([^;\r\n]+?)\s*;\s*No clock feeds this register')
        if ($unclocked.Count -ne $summary['no_clock']) {throw 'Incomplete no-clock node inventory.'}
        foreach ($node in $unclocked) {
            $name = $node.Groups[1].Value.Trim()
            # These ~FF_N nodes are timing-model placeholders inside HPS hard
            # GPIO/SPI/I2C/SDRAM and h2f clock/reset primitives, not FPGA fabric registers.
            if ($name -notmatch '^(spi|h2f_gp|hdmi_i2c)~FF_\d+$' -and
                $name -notmatch '^sysmem_lite:sysmem\|.*\|(f2sdram|clocks_resets)~FF_\d+$') {
                throw "Unclocked fabric or unreviewed model register: $name"
            }
        }
        $hpsModels += [ordered]@{corner=$model.corner; unclocked_hps_model_nodes=$unclocked.Count}
    }
    [ordered]@{ corners=$models; results=$results; unconstrained_setup_and_hold_counts=0; hps_model_review=$hpsModels }
}
