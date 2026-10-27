param(
    [Parameter(Mandatory=$true)][string]$Installer,
    [Parameter(Mandatory=$true)][string]$Video,
    [Parameter(Mandatory=$true)][string]$Manifest,
    [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows runner required.' }
$Installer = (Resolve-Path $Installer).Path
$Video = (Resolve-Path $Video).Path
$Manifest = (Resolve-Path $Manifest).Path
$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
New-Item -ItemType Directory -Force $Output | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('Zone-installer-test-' + [Guid]::NewGuid().ToString('N'))
$app = Join-Path $work 'installed'
New-Item -ItemType Directory -Force $work | Out-Null
$originalLocal = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $work 'profile'
$profile = Join-Path $env:LOCALAPPDATA 'Gramercy Systems\Zone Windows'
New-Item -ItemType Directory -Force $profile | Out-Null
$sentinel = Join-Path $profile 'retain-me.txt'
Set-Content -Path $sentinel -Value 'Installer must retain local settings and progress.'
function Invoke-Bounded([string]$File, [string[]]$Arguments, [int]$Timeout=120000) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit($Timeout)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw "Process timed out: $File"
    }
    if ($process.ExitCode -ne 0) { throw "Process failed with $($process.ExitCode): $File" }
}
try {
    Invoke-Bounded $Installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $app + '"'), ('/LOG="' + (Join-Path $Output 'install.log') + '"'))
    $exe = Join-Path $app 'Zone.exe'
    if (-not (Test-Path $exe)) { throw 'Installed executable is missing.' }
    $installedHash = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLowerInvariant()
    Invoke-Bounded $exe @('--self-test', '--video', ('"' + $Video + '"'), '--manifest', ('"' + $Manifest + '"'), '--output', ('"' + (Join-Path $Output 'installed') + '"'), '--widgets')
    $report = Get-Content (Join-Path $Output 'installed\video-report.json') -Raw | ConvertFrom-Json
    if ($report.frozen -ne $true -or $report.platform -notlike 'Windows*') { throw 'Installed EXE did not prove its platform/frozen identity.' }
    if (-not (Test-Path $sentinel)) { throw 'Installation deleted the isolated profile sentinel.' }
    # Exercise the production single-instance and update handshake in an off
    # session. The isolated profile has no calibration and never enables capture.
    $owner = Start-Process -FilePath $exe -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 200
        $owner.Refresh()
        if ($owner.HasExited) { throw 'Installed app failed during ordinary camera-off startup.' }
    } while ($owner.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($owner.MainWindowHandle -eq 0) { throw 'Ordinary controls did not appear.' }
    Invoke-Bounded $Installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $app + '"'), ('/LOG="' + (Join-Path $Output 'upgrade.log') + '"'))
    if (-not $owner.WaitForExit(10000)) { throw 'Upgrade did not release its old process.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 200
        $replacement = @(Get-Process -Name Zone -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -and $_.Id -ne $owner.Id })
        $handoffConsumed = -not (Test-Path (Join-Path $profile 'update-handoff.json'))
    } while (($replacement.Count -ne 1 -or -not $handoffConsumed) -and [DateTime]::UtcNow -lt $deadline)
    if ($replacement.Count -ne 1 -or -not $handoffConsumed) { throw 'Upgrade did not consume its one-use handoff into one replacement app.' }
    Invoke-Bounded (Join-Path $app 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + (Join-Path $Output 'uninstall.log') + '"'))
    if (Test-Path $exe) { throw 'Uninstall left the installed executable behind.' }
    if (-not (Test-Path $sentinel)) { throw 'Uninstall deleted retained settings/history.' }
    @{
        schema=1; platform=[Environment]::OSVersion.VersionString;
        installerSha256=(Get-FileHash -Algorithm SHA256 $Installer).Hash.ToLowerInvariant();
        installedExecutableSha256=$installedHash; installedExecutableTested=$true;
        uninstallRemovedExecutable=$true; profilePreserved=$true;
        runningAppUpgrade=$true; oneReplacementProcess=$true; updateHandoffConsumed=$true;
        cameraOpened=$false; profile='isolated temporary test profile'
    } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $Output 'installer-report.json')
} finally {
    Get-Process -Name Zone -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $app 'Zone.exe') } | Stop-Process -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocal
    # Keep evidence. Only remove the owned unique temporary fixture directory.
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
}
