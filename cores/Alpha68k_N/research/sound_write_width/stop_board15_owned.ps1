$ErrorActionPreference='Stop'
$ownerId=46508
$leafId=2840
$expectedProject='D:\Arcade\AI\aCORES\Alpha68k N\research\board15_complete_check\Alpha68k_N.qpf'
$observed=Get-CimInstance Win32_Process
$owner=$observed | Where-Object ProcessId -eq $ownerId
$leaf=$observed | Where-Object ProcessId -eq $leafId
if(!$owner -or !$owner.CommandLine.Contains($expectedProject)) { throw 'Owned controller identity mismatch; no stop performed' }
if(!$leaf) { Write-Output 'Owned fit already exited; no stop performed'; exit 0 }
if($leaf.ParentProcessId -ne $ownerId -or $leaf.Name -ne 'quartus_fit.exe' -or !$leaf.CommandLine.StartsWith('D:\q17\quartus\bin64\quartus_fit.exe Alpha68k_N -c Alpha68k_N ')) { throw 'Owned fit identity mismatch; no stop performed' }
$owned=@($leaf)
do {
 $ids=@($owned | ForEach-Object ProcessId)
 $next=@($observed | Where-Object { $_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids })
 $owned+=$next
} while($next.Count -gt 0)
foreach($node in $owned) {
 if(!$node.ExecutablePath -or !$node.ExecutablePath.StartsWith('D:\q17\quartus\bin64\',[System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected owned descendant executable; no stop performed' }
}
$record=[ordered]@{ status='cancelled_our_fit_only'; utc=[DateTime]::UtcNow.ToString('o'); parent_id=$ownerId; leaf_id=$leafId; reason='Actual15-bit-only complete map0 still estimates372510ALMs/548181registers; soundROM missingRAM. Gross devicecapacityfailure; no usefulfit/STA. NoRBF.'; exact_owned_processes=@($owned | Select-Object ProcessId,ParentProcessId,Name,CommandLine); expected_project=$expectedProject; unrelated_jobs_touched=$false }
foreach($node in @($owned | Sort-Object ProcessId -Descending)) {
 $still=Get-CimInstance Win32_Process -Filter ('ProcessId='+$node.ProcessId)
 if($still -and $still.ParentProcessId -eq $node.ParentProcessId -and $still.CommandLine -eq $node.CommandLine) { Stop-Process -Id $node.ProcessId -Force -ErrorAction Stop }
}
$record | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath 'D:\Arcade\AI\aCORES\Alpha68k N\research\sound_write_width\board15_owned_cancel.json' -Encoding utf8
$record | ConvertTo-Json -Depth 7 -Compress
