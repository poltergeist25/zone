param([Parameter(Mandatory=$true)][string]$InstallPath, [switch]$AcceptLicense)
$ErrorActionPreference = 'Stop'
# The person running this helper must review and accept Microsoft's terms.
# The original maintainer's approval does not apply to another builder.
if (-not $AcceptLicense) { throw 'Review https://visualstudio.microsoft.com/license-terms/vs2022-ga-community/ and rerun with -AcceptLicense only if eligible and authorized to accept.' }
$evidence = Join-Path $PSScriptRoot '..\ci-evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$runtimeScratch = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$bootstrap = Join-Path $runtimeScratch 'zone-vs-community-2022.exe'
$url = 'https://aka.ms/vs/17/release/vs_community.exe'
Invoke-WebRequest -Uri $url -OutFile $bootstrap
$signature = Get-AuthenticodeSignature $bootstrap
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw 'The Community bootstrapper is not valid Microsoft-signed software.'
}
$arguments = @('--quiet', '--wait', '--norestart', '--nocache', '--installPath', $InstallPath,
    '--add', 'Microsoft.VisualStudio.Component.VC.Redist.14.Latest',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64')
$process = Start-Process -FilePath $bootstrap -ArgumentList $arguments -PassThru -Wait
if ($process.ExitCode -notin @(0, 3010)) { throw "Community installation failed: $($process.ExitCode)" }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$instances = @(& $vswhere -products Microsoft.VisualStudio.Product.Community -version '[17.0,18.0)' -format json | ConvertFrom-Json)
$instance = @($instances | Where-Object { $_.installationPath -eq $InstallPath -and $_.isComplete -and -not $_.isPrerelease })
if ($instance.Count -ne 1) { throw 'No unique completed release-channel Community 2022 installation.' }
$instance[0] | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $evidence 'community-installation.json')
Get-ChildItem (Join-Path $InstallPath 'VC\Redist') -Recurse -File |
    Select-Object FullName, Length | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $evidence 'community-redist-files.json')
$crt = @(Get-ChildItem (Join-Path $InstallPath 'VC\Redist\MSVC') -Directory |
    Where-Object { $_.Name -match '^14\.[0-9]+\.[0-9]+$' } | Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } | Where-Object { Test-Path $_ } | Select-Object -First 1)
if ($crt.Count -ne 1 -or -not (Test-Path (Join-Path $crt[0] 'vcruntime140.dll'))) { throw 'Official x64 CRT files are missing.' }
$receipt = [ordered]@{
    schema = 1; acceptedUnder = 'explicit-builder-opt-in'; acceptedAt = (Get-Date).ToUniversalTime().ToString('o')
    licenseUrl = 'https://visualstudio.microsoft.com/license-terms/vs2022-ga-community/'
    licenseTextSha256 = (Get-FileHash (Join-Path $PSScriptRoot 'runtime-notices\Microsoft-Visual-Studio-Community-2022.txt')).Hash.ToLower()
    bootstrapUrl = $url; bootstrapSha256 = (Get-FileHash $bootstrap).Hash.ToLower()
    bootstrapSigner = $signature.SignerCertificate.Subject; exitCode = $process.ExitCode
    productId = $instance[0].productId; installationVersion = $instance[0].installationVersion
    installationPath = $InstallPath; runtimeDirectory = $crt[0]
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $evidence 'community-acquisition.json')
if ($env:GITHUB_ENV) { "ZONE_VC_RUNTIME=$($crt[0])" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8 }
Write-Host "Installed release-channel Visual Studio Community $($instance[0].installationVersion); official x64 CRT located."
