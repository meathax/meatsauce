# Pure Git/source preparation: this script never launches an FPGA compiler.
param(
    [string]$ProjectRoot = '',
    [string]$QuartusBin = 'D:\q17\quartus\bin64',
    [string]$Queue = 'D:\vibes\fpga\bin\quartus-safe.ps1'
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME,'Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Join-Path $PSScriptRoot '..' }
$projectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'Nintendo8080.qpf') -PathType Leaf)) {
    throw 'ProjectRoot must contain the Sheriff Nintendo8080.qpf project.'
}
$repositoryRoot = & git -C $projectRoot rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) { throw 'Cannot read project Git metadata. Supply -ProjectRoot with the canonical core directory when using legacy aliases.' }
$repositoryRoot = $repositoryRoot.Trim()
$dirty = & git -C $projectRoot status --porcelain --untracked-files=normal -- .
if ($LASTEXITCODE -ne 0) { throw 'Cannot read scoped project Git status.' }
if ($dirty) { throw 'Commit the intended core source snapshot before preparation.' }
$revision = & git -C $projectRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source revision.' }
$revision = $revision.Trim()
$prefix = & git -C $projectRoot rev-parse --show-prefix
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the project subtree.' }
$prefix = ([string]$prefix).Trim().TrimEnd('/')
$archiveTree = if ($prefix) { '{0}:{1}' -f $revision,$prefix } else { $revision }
$treeSelector = if ($prefix) { $archiveTree } else { '{0}^{{tree}}' -f $revision }
$treeObject = & git -C $repositoryRoot rev-parse $treeSelector
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the committed project tree.' }
$checkRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '_checks'))
$runName = $revision.Substring(0,12) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$runPath = [IO.Path]::GetFullPath((Join-Path $checkRoot $runName))
if (-not $runPath.StartsWith($checkRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid check snapshot path.' }
if (Test-Path -LiteralPath $runPath) { throw 'Existing check directory; preserve its receipts.' }
New-Item -ItemType Directory -Path $runPath | Out-Null
$archivePath = Join-Path $runPath 'source.zip'
& git -C $repositoryRoot archive --format=zip --output=$archivePath $archiveTree
if ($LASTEXITCODE -ne 0) { throw 'Core source snapshot archive failed.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$snapshotPath = Join-Path $runPath 'source'
[IO.Compression.ZipFile]::ExtractToDirectory($archivePath,$snapshotPath)
foreach ($name in @('Nintendo8080.qpf','Nintendo8080.qsf','Nintendo8080.sv','files.qip','sys/sys.qip','sys/build_id.tcl','rtl/n8080_board.sv')) {
    if (-not (Test-Path -LiteralPath (Join-Path $snapshotPath $name) -PathType Leaf)) { throw "Snapshot is missing required project input: $name" }
}
$rbfAssignments = [regex]::Matches([IO.File]::ReadAllText((Join-Path $snapshotPath 'Nintendo8080.qsf')),'(?im)^\s*set_global_assignment\s+-name\s+GENERATE_RBF_FILE\s+(\S+)\s*$')
if ($rbfAssignments.Count -eq 0 -or @($rbfAssignments | Where-Object { $_.Groups[1].Value.Trim('"') -ine 'OFF' }).Count -ne 0) {
    throw 'Snapshot must explicitly retain GENERATE_RBF_FILE OFF.'
}
$flowPath = Join-Path $snapshotPath 'development_check.tcl'
$flow = @'
package require ::quartus::project
package require ::quartus::flow
set quartus(args) [list compile Nintendo8080 Nintendo8080]
source sys/build_id.tcl
project_open Nintendo8080 -revision Nintendo8080
if {[string toupper [get_global_assignment -name GENERATE_RBF_FILE]] ne "OFF"} {
    error "Development checks require GENERATE_RBF_FILE OFF"
}
execute_module -tool map
execute_module -tool fit
execute_module -tool sta
project_close
'@
[IO.File]::WriteAllText($flowPath,$flow,[Text.UTF8Encoding]::new($false))
$hashes = [ordered]@{}
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName.EndsWith('/')) { continue }
        if ($entry.FullName -match '^(roms|donors)/' -or $entry.FullName -eq 'mister.env') { throw 'Local ROM/donor/environment data must not enter a source archive.' }
        $path = [IO.Path]::GetFullPath((Join-Path $snapshotPath $entry.FullName))
        if (-not $path.StartsWith($snapshotPath + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Archive entry escapes the snapshot.' }
        $hashes[$entry.FullName] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} finally { $zip.Dispose() }
[ordered]@{
    revision=$revision; repository=$repositoryRoot; project_root=$projectRoot;
    project_prefix=$prefix; archive_tree=$archiveTree; tree_object=([string]$treeObject).Trim();
    archive_sha256=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant();
    snapshot=$snapshotPath; stage='prepared-map-fit-sta'; source_sha256=$hashes;
    flow_sha256=(Get-FileHash -LiteralPath $flowPath -Algorithm SHA256).Hash.ToLowerInvariant();
    quartus_bin=$QuartusBin; queue=$Queue; finished_utc=[DateTime]::UtcNow.ToString('o');
    preparation_exit_code=0; compiler_invoked=$false; queue_recipe_admitted=$false;
    map_fit_sta_complete=$false; resource_gate_pass=$false; assembly_requested=$false
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runPath 'preparation.json') -Encoding UTF8
Write-Output "Prepared Sheriff source tree $archiveTree. Receipt: $runPath\preparation.json"
Write-Output 'Compiler execution remains blocked on independent reviewed preassembly recipe admission; no Quartus, assembler, RBF conversion or deployment was invoked.'
