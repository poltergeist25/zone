param([Parameter(Mandatory=$true)][string]$RuntimeDirectory,
      [Parameter(Mandatory=$true)][string]$AppDirectory)
$ErrorActionPreference = 'Stop'
$runtime = (Resolve-Path $RuntimeDirectory).Path
$app = (Resolve-Path $AppDirectory).Path
if ($runtime -notmatch '\\VC\\Redist\\MSVC\\14\.[0-9]+\.[0-9]+\\x64\\Microsoft\.VC143\.CRT$') {
    throw 'Runtime source must be the installed Community x64 redistributable directory.'
}
$sources = @{}
foreach ($source in Get-ChildItem $runtime -Filter '*.dll' -File) {
    $signature = Get-AuthenticodeSignature $source.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "Unverified official runtime: $($source.Name)"
    }
    $sources[$source.Name.ToLower()] = $source
}
if (-not $sources.ContainsKey('vcruntime140.dll') -or -not $sources.ContainsKey('msvcp140.dll')) { throw 'Incomplete runtime source.' }
$removed = @()
$replaced = @()
foreach ($file in Get-ChildItem $app -Filter '*.dll' -Recurse -File) {
    $name = $file.Name.ToLower()
    if ($name -eq 'ucrtbase.dll' -or $name -like 'api-ms-win-*.dll') {
        # Windows 11 supplies the serviced Universal CRT and API-set forwarding.
        $removed += [ordered]@{ path = [IO.Path]::GetRelativePath($app, $file.FullName); sha256 = (Get-FileHash $file.FullName).Hash.ToLower() }
        Remove-Item $file.FullName
    } elseif ($name -match '^(vcruntime|msvcp|concrt)140.*\.dll$') {
        # NumPy's loader expects its vendored hash-suffixed name. Keep that name,
        # but copy the official DLL bytes unchanged and verify the result.
        $canonical = $name -replace '-[a-f0-9]+(?=\.dll$)', ''
        if (-not $sources.ContainsKey($canonical)) { throw "No official replacement for $name" }
        $source = $sources[$canonical]
        $oldHash = (Get-FileHash $file.FullName).Hash.ToLower()
        Copy-Item $source.FullName $file.FullName -Force
        $expected = (Get-FileHash $source.FullName).Hash.ToLower()
        if ((Get-FileHash $file.FullName).Hash.ToLower() -ne $expected) { throw 'Runtime copy hash mismatch.' }
        $replaced += [ordered]@{ path = [IO.Path]::GetRelativePath($app, $file.FullName); source = $source.Name; sha256 = $expected; previousSha256 = $oldHash }
    }
}
# Supply all companion CRT libraries beside the Python DLL, as an app-local
# runtime. No machine-wide runtime installer or administrator access is needed.
foreach ($source in $sources.Values) { Copy-Item $source.FullName (Join-Path $app "_internal\$($source.Name)") -Force }
$inventory = @()
foreach ($file in Get-ChildItem $app -Filter '*.dll' -Recurse -File) {
    if ($file.Name -match '^(vcruntime|msvcp|concrt)140.*\.dll$') {
        $canonical = $file.Name.ToLower() -replace '-[a-f0-9]+(?=\.dll$)', ''
        $source = $sources[$canonical]
        $hash = (Get-FileHash $file.FullName).Hash.ToLower()
        if (-not $source -or $hash -ne (Get-FileHash $source.FullName).Hash.ToLower()) { throw 'Packaged runtime does not match official source.' }
        $inventory += [ordered]@{ path = [IO.Path]::GetRelativePath($app, $file.FullName); source = $source.Name; sha256 = $hash; version = $source.VersionInfo.FileVersion }
    }
}
$report = [ordered]@{ schema = 1; sourceDirectory = $runtime; files = $inventory; replaced = $replaced; removedOsRuntime = $removed; osRuntime = 'Windows 11 system Universal CRT'; unmodifiedMicrosoftSignaturesVerified = $true }
$report | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot '..\ci-evidence\runtime-provenance.json')
Write-Host "Verified $($inventory.Count) official app-local Microsoft runtime files; removed $($removed.Count) OS runtime copies."
