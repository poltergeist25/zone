param(
    [Parameter(Mandatory=$true)][string]$CertificateThumbprint,
    [Parameter(Mandatory=$true)][string[]]$Files,
    [string]$ExpectedPublisher = 'Gramercy Systems 212 Inc'
)
$ErrorActionPreference = 'Stop'
# Uses an existing authorized CurrentUser signing certificate only. No new
# certificate, key export, account, subscription or cloud permission is created.
$thumbprint = $CertificateThumbprint.Replace(' ', '').ToUpperInvariant()
if ($thumbprint -notmatch '^[0-9A-F]{40}$') { throw 'Specify the exact authorized certificate thumbprint.' }
$certificate = Get-Item ('Cert:\CurrentUser\My\' + $thumbprint)
if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le [DateTime]::Now) { throw 'The signing certificate is expired or has no usable private key.' }
if ($certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne $ExpectedPublisher) { throw 'Signing identity does not match the expected legal publisher.' }
if (-not ($certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) { throw 'Certificate is not authorized for code signing.' }
$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$tool = Get-ChildItem -Path $kits -Filter signtool.exe -Recurse | Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $tool) { throw 'Install the official Windows SDK signing tools.' }
foreach ($file in $Files) {
    $target = (Resolve-Path $file).Path
    & $tool.FullName sign /sha1 $thumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $target
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $target" }
    & $tool.FullName verify /pa /all /v $target
    if ($LASTEXITCODE -ne 0) { throw "Signature verification failed: $target" }
    $signature = Get-AuthenticodeSignature $target
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $thumbprint -or -not $signature.TimeStamperCertificate) { throw "Public signature or timestamp is not valid: $target" }
}
