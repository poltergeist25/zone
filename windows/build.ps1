param([switch]$Qualify, [switch]$Installer, [string]$CertificateThumbprint, [string]$OfficialRuntimeDirectory)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Build this target on Windows.' }
Set-Location $PSScriptRoot
py -3.12 -m venv .venv
if ($LASTEXITCODE -ne 0) { throw 'Install Python 3.12 x64 first.' }
$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
& $python -m pip install -r requirements.txt pyinstaller==6.22.3
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
& $python bootstrap.py
if ($LASTEXITCODE -ne 0) { throw 'Model verification failed.' }
& $python packaging/prepare.py --prepare --notices packaging/generated-notices
if ($LASTEXITCODE -ne 0) { throw 'Icon/version/license preparation failed.' }
& $python -m unittest discover -s tests -p 'test_*.py'
if ($LASTEXITCODE -ne 0) { throw 'Acceptance checks failed.' }
if ($Qualify) {
    New-Item -ItemType Directory -Force ci-evidence | Out-Null
    & $python -m pip freeze | Set-Content -Encoding utf8 ci-evidence/dependencies.txt
    & $python tests/make_video_fixture.py ci-fixture
    if ($LASTEXITCODE -ne 0) { throw 'Video fixture creation failed.' }
    & $python -m zone.qualification --video ci-fixture/posture-motion.avi --manifest ci-fixture/manifest.json --output ci-evidence/python --widgets
    if ($LASTEXITCODE -ne 0) { throw 'Windows source/video qualification failed.' }
}
& $python -m PyInstaller --noconfirm --clean --windowed --onedir --name Zone --icon packaging/zone.ico --version-file packaging/version_info.txt --collect-all mediapipe --copy-metadata tzdata --collect-data tzdata --add-data 'assets;assets' --add-data 'THIRD-PARTY.md;.' --add-data 'packaging/generated-notices;licenses' --add-data 'packaging/modelnotices;licenses/model' --add-data 'packaging/installer-license.txt;licenses/runtime' --add-data 'packaging/runtime-notices/Microsoft-Visual-C-Runtime-2015-2022.txt;licenses/runtime' --add-data 'packaging/licensing.md;licenses' run_zone.py
if ($LASTEXITCODE -ne 0) { throw 'Windows packaging failed.' }
# Native QWidget controls use the raster paint engine. This optional 20+ MB
# Mesa software-OpenGL fallback is not used; test the actual package without it.
Get-ChildItem dist/Zone -Filter opengl32sw.dll -Recurse | Remove-Item
# Camera input uses DirectShow. Fixture replay uses built-in MJPEG AVI; neither
# needs this optional LGPL video-codec plugin. Retain upstream notices verbatim.
Get-ChildItem dist/Zone -Filter 'opencv_videoio_ffmpeg*.dll' -Recurse | Remove-Item
# MediaPipe imports sounddevice but Zone never captures audio. Keep only its
# ordinary x64 loader dependency; do not ship ASIO or other-platform binaries.
$portaudio = 'dist/Zone/_internal/_sounddevice_data/portaudio-binaries'
if (Test-Path $portaudio) {
    Get-ChildItem $portaudio -File | Where-Object { $_.Name -notin @('libportaudio64bit.dll', 'README.md') } | Remove-Item
}
if ($Installer -and -not $OfficialRuntimeDirectory) { throw 'A beta installer requires the verified official Community runtime.' }
if ($OfficialRuntimeDirectory) { & ./packaging/stage-runtime.ps1 -RuntimeDirectory $OfficialRuntimeDirectory -AppDirectory dist/Zone }
if ($CertificateThumbprint) {
    & ./packaging/sign-release.ps1 -CertificateThumbprint $CertificateThumbprint -Files dist/Zone/Zone.exe
}
& $python packaging/prepare.py --manifest dist/Zone
if ($LASTEXITCODE -ne 0) { throw 'Release tree manifest failed.' }
if ($Qualify) {
    $exe = Join-Path $PSScriptRoot 'dist\Zone\Zone.exe'
    $video = Join-Path $PSScriptRoot 'ci-fixture\posture-motion.avi'
    $manifest = Join-Path $PSScriptRoot 'ci-fixture\manifest.json'
    $output = Join-Path $PSScriptRoot 'ci-evidence\packaged'
    $arguments = @('--self-test', '--video', ('"' + $video + '"'), '--manifest', ('"' + $manifest + '"'), '--output', ('"' + $output + '"'), '--widgets')
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru
    if (-not $process.WaitForExit(120000)) {
        Stop-Process -Id $process.Id
        throw 'Packaged self-test exceeded its two-minute deadline.'
    }
    if ($process.ExitCode -ne 0) { throw 'Packaged executable self-test failed.' }
    if (-not (Test-Path (Join-Path $output 'video-report.json'))) { throw 'Packaged self-test produced no receipt.' }
    $receipt = Get-Content (Join-Path $output 'video-report.json') -Raw | ConvertFrom-Json
    if ($receipt.frozen -ne $true -or $receipt.platform -notlike 'Windows*') { throw 'Receipt does not prove a frozen Windows process.' }
    Get-FileHash -Algorithm SHA256 $exe | Format-List | Out-File ci-evidence/executable-sha256.txt
    Compress-Archive -Path dist/Zone -DestinationPath dist/Zone-Windows-x64.zip -Force
    Get-FileHash -Algorithm SHA256 dist/Zone-Windows-x64.zip | Format-List | Out-File ci-evidence/archive-sha256.txt
}
if ($Installer) {
    $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    if (-not (Test-Path $compiler)) { throw 'Install official Inno Setup 6 before creating the installer.' }
    $sha = (Get-FileHash dist/Zone/Zone.exe -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Content -Encoding utf8 packaging/version.iss ('#define ZoneExeSHA256 "' + $sha + '"')
    & $compiler packaging/Zone.iss
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    if ($CertificateThumbprint) {
        & ./packaging/sign-release.ps1 -CertificateThumbprint $CertificateThumbprint -Files dist/Zone-1.0.0-beta.1-Windows-x64-Setup.exe
    }
    & $python packaging/license_sources.py --verify-model assets/face_landmarker.task --output dist/Zone-1.0.0-beta.1-Dependency-Sources.zip --cache source-cache
    if ($LASTEXITCODE -ne 0) { throw 'Dependency source companion verification failed.' }
    if ($Qualify) {
        $installerEvidence = Join-Path $PSScriptRoot 'ci-evidence\installer'
        & ./packaging/test-installer.ps1 -Installer dist/Zone-1.0.0-beta.1-Windows-x64-Setup.exe -Video ci-fixture/posture-motion.avi -Manifest ci-fixture/manifest.json -Output $installerEvidence
        $installerReceipt = Join-Path $installerEvidence 'installer-report.json'
        if (-not (Test-Path $installerReceipt)) { throw 'Installer test produced no retained receipt.' }
        $installed = Get-Content $installerReceipt -Raw | ConvertFrom-Json
        if (-not ($installed.installedExecutableTested -and $installed.runningAppUpgrade -and $installed.oneReplacementProcess -and $installed.updateHandoffConsumed -and $installed.uninstallRemovedExecutable -and $installed.profilePreserved)) { throw 'Installer acceptance is incomplete.' }
        if ($installed.installedExecutableSha256 -ne $sha) { throw 'Installer tested a different application binary.' }
        if (Get-ChildItem dist/Zone -Filter 'opencv_videoio_ffmpeg*.dll' -Recurse) { throw 'Unused FFmpeg plugin was unexpectedly bundled.' }
    }
    Get-FileHash dist/Zone-1.0.0-beta.1-Windows-x64-Setup.exe, dist/Zone-1.0.0-beta.1-Dependency-Sources.zip -Algorithm SHA256 | Format-List | Out-File ci-evidence/distribution-sha256.txt
}
Write-Host 'Built Zone x64 candidate. Public signing remains separate; no Windows camera/CPU claim is inferred from fixture tests.'
