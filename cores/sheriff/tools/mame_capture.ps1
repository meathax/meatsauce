# Real MAME 0.289 reference; no game memory/ROM patch or FPGA assembly.
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$Inputs,
    [int]$Frames=6000,
    [switch]$SoundProbe,
    [switch]$ExactObservations,
    [switch]$WaitForExit,
    [string]$InputPolicy='',
    [int]$WriteProbeFrame=-1,
    [int]$InputProbeFrame=-1,
    [string]$Mame='D:\Arcade\AI\mameexe\mame.exe',
    [string]$RomPath='D:\Arcade\AI\MAME 0.289 ROMs (merged)'
)
$ErrorActionPreference='Stop'
$projectPath=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$destination=[IO.Path]::GetFullPath((Join-Path $projectPath $OutputDirectory))
if (!$destination.StartsWith($projectPath+[IO.Path]::DirectorySeparatorChar)) { throw 'Capture must stay in this project' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$inputPath=(Resolve-Path (Join-Path $projectPath $Inputs)).Path
$previousCapture=$env:SHERIFF_CAPTURE;$previousFrames=$env:SHERIFF_FRAMES;$previousInputs=$env:SHERIFF_INPUTS
$previousSoundProbe=$env:SHERIFF_SOUND_PROBE
$previousExactObservations=$env:SHERIFF_EXACT_OBSERVATIONS
$previousInputPolicy=$env:SHERIFF_INPUT_POLICY
$previousWriteProbe=$env:SHERIFF_WRITE_PROBE_FRAME
$previousInputProbe=$env:SHERIFF_INPUT_PROBE_FRAME
$policyPath=if($InputPolicy){(Resolve-Path (Join-Path $projectPath $InputPolicy)).Path}else{''}
$previousCaptureLuaHash=$env:SHERIFF_CAPTURE_LUA_SHA256
$previousCaptureLauncherHash=$env:SHERIFF_CAPTURE_LAUNCHER_SHA256
try {
    $env:SHERIFF_CAPTURE=$destination.Replace('\','/')
    $env:SHERIFF_FRAMES=[string]$Frames
    $env:SHERIFF_INPUTS=$inputPath.Replace('\','/')
    $env:SHERIFF_SOUND_PROBE=if($SoundProbe){'1'}else{'0'}
    $env:SHERIFF_EXACT_OBSERVATIONS=if($ExactObservations){'1'}else{'0'}
    $env:SHERIFF_INPUT_POLICY=$policyPath.Replace('\','/')
    $env:SHERIFF_WRITE_PROBE_FRAME=[string]$WriteProbeFrame
    $env:SHERIFF_INPUT_PROBE_FRAME=[string]$InputProbeFrame
    $arguments=@('sheriff','-rompath',('"'+$RomPath+'"'),'-video','none','-sound','none',
        '-nothrottle','-nosleep','-skip_gameinfo','-noplugins','-autoboot_delay','0',
        '-autoboot_script','sim/mame_capture.lua','-wavwrite',('"'+(Join-Path $destination 'audio.wav')+'"'),
        '-cfg_directory',('"'+(Join-Path $destination 'cfg')+'"'),
        '-nvram_directory',('"'+(Join-Path $destination 'nvram')+'"'))
    # Freeze the Lua that will actually execute, and the bytes of this invocation's launcher.
    $sourceDirectory=Join-Path $destination 'capture_source'
    New-Item -ItemType Directory -Force -Path $sourceDirectory | Out-Null
    $luaSnapshot=Join-Path $sourceDirectory 'mame_capture.lua'
    $launcherSnapshot=Join-Path $sourceDirectory 'mame_capture.ps1'
    $luaHash=(Get-FileHash -LiteralPath (Join-Path $projectPath 'sim/mame_capture.lua') -Algorithm SHA256).Hash
    $launcherHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    foreach ($entry in @(@((Join-Path $projectPath 'sim/mame_capture.lua'),$luaSnapshot,$luaHash),@($PSCommandPath,$launcherSnapshot,$launcherHash))) {
        if (Test-Path -LiteralPath $entry[1]) {
            if ((Get-FileHash -LiteralPath $entry[1] -Algorithm SHA256).Hash -ne $entry[2]) { throw 'Capture source snapshot already exists with different bytes; use a new output directory' }
        } else { Copy-Item -LiteralPath $entry[0] -Destination $entry[1] }
        if ((Get-FileHash -LiteralPath $entry[1] -Algorithm SHA256).Hash -ne $entry[2]) { throw 'Capture source changed while being frozen' }
    }
    $env:SHERIFF_CAPTURE_LUA_SHA256=$luaHash
    $env:SHERIFF_CAPTURE_LAUNCHER_SHA256=$launcherHash
    $scriptArgument=[Array]::IndexOf($arguments,'-autoboot_script')+1
    if ($scriptArgument -le 0) { throw 'Missing autoboot script argument' }
    $arguments[$scriptArgument]='"'+$luaSnapshot+'"'
    $captureStarted=[DateTime]::UtcNow.ToString('o')
    $process=Start-Process -FilePath $Mame -WorkingDirectory $projectPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $destination 'stdout.log') -RedirectStandardError (Join-Path $destination 'stderr.log')
    # Retain the original process handle before it exits. Reacquiring a
    # Process with Get-Process can leave ExitCode unavailable after waiting.
    $null=$process.Handle
    $process.Id | Set-Content (Join-Path $destination 'process.pid')
    Get-FileHash -LiteralPath $inputPath -Algorithm SHA256 | Select-Object Hash | ConvertTo-Json | Set-Content (Join-Path $destination 'input_sha256.json')
    @{sound_probe=[bool]$SoundProbe;exact_observations=[bool]$ExactObservations;write_probe_frame=$WriteProbeFrame;input_probe_frame=$InputProbeFrame;irq_probe=($env:SHERIFF_IRQ_PROBE -eq '1');irq_frame=$env:SHERIFF_IRQ_FRAME;lua_sha256=$luaHash;lua_snapshot=$luaSnapshot;launcher_sha256=$launcherHash;launcher_snapshot=$launcherSnapshot;launcher_invocation=$PSCommandPath;input_policy_sha256=$(if($policyPath){(Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash}else{$null})} | ConvertTo-Json | Set-Content (Join-Path $destination 'capture_features.json')
    "MAME_PID=$($process.Id) OUTPUT=$destination FRAMES=$Frames"
    if ($WaitForExit) {
        $process.WaitForExit()
        $captureSourceStable=((Get-FileHash -LiteralPath $luaSnapshot -Algorithm SHA256).Hash -eq $luaHash) -and ((Get-FileHash -LiteralPath $launcherSnapshot -Algorithm SHA256).Hash -eq $launcherHash) -and ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -eq $launcherHash)
        @{source_snapshots_stable=$captureSourceStable;lua_sha256=$luaHash;launcher_sha256=$launcherHash;launcher_invocation=$PSCommandPath} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'capture_source_verification.json') -Encoding UTF8
        if (-not $captureSourceStable) { throw 'Capture source changed during execution; provenance is not qualified' }
        $captureExitCode=$process.ExitCode
        if ($null -eq $captureExitCode) { throw 'MAME exit code unavailable; capture is not a runtime pass' }
        @{started_utc=$captureStarted;finished_utc=[DateTime]::UtcNow.ToString('o');exit_code=$captureExitCode;process_id=$process.Id;frames_requested=$Frames;lua_sha256=$luaHash;lua_snapshot=$luaSnapshot;launcher_sha256=$launcherHash;launcher_snapshot=$launcherSnapshot;launcher_invocation=$PSCommandPath} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'exit.json') -Encoding UTF8
        if ($captureExitCode -ne 0) { throw "MAME capture exited with code $captureExitCode" }
    }
} finally {
    $env:SHERIFF_CAPTURE_LUA_SHA256=$previousCaptureLuaHash
    $env:SHERIFF_CAPTURE_LAUNCHER_SHA256=$previousCaptureLauncherHash
    $env:SHERIFF_CAPTURE=$previousCapture;$env:SHERIFF_FRAMES=$previousFrames;$env:SHERIFF_INPUTS=$previousInputs
    $env:SHERIFF_SOUND_PROBE=$previousSoundProbe
    $env:SHERIFF_EXACT_OBSERVATIONS=$previousExactObservations
    $env:SHERIFF_INPUT_POLICY=$previousInputPolicy
    $env:SHERIFF_WRITE_PROBE_FRAME=$previousWriteProbe
    $env:SHERIFF_INPUT_PROBE_FRAME=$previousInputProbe
}
