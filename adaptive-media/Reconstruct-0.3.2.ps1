#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Destination)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$media = $PSScriptRoot
$target = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $target) { throw "Destination already exists; refusing to overwrite: $target" }
$parent = [IO.Path]::GetDirectoryName($target)
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Destination parent must already exist.' }
$cursor = $parent
while ($cursor) {
    if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Destination cannot pass through a reparse point.' }
    $cursor = [IO.Path]::GetDirectoryName($cursor)
}
$expected = ((Get-Content -LiteralPath (Join-Path $media 'AdaptiveMedia-0.3.0-Source.sha256.txt') -Raw) -replace [char]0xFEFF,'').Trim()
if ($expected -notmatch '^([0-9a-fA-F]{64})(\s|$)') { throw 'Invalid archive SHA-256 file.' }
$expected = $Matches[1].ToUpperInvariant()
$parts = @(Get-ChildItem -LiteralPath $media -Filter 'AdaptiveMedia-0.3.0-Source.part*.b64' -File | Sort-Object Name)
if ($parts.Count -ne 5) { throw 'Expected exactly five transport parts.' }
for ($i=0; $i -lt 5; $i++) { if ($parts[$i].Name -ne ('AdaptiveMedia-0.3.0-Source.part{0:00}.b64' -f $i)) { throw 'Unexpected transport part sequence.' } }
$bytes = [Convert]::FromBase64String((($parts | ForEach-Object { [IO.File]::ReadAllText($_.FullName).Trim() }) -join ''))
$sha = [Security.Cryptography.SHA256]::Create()
try { $actual = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') } finally { $sha.Dispose() }
if ($actual -ne $expected) { throw "Archive SHA-256 mismatch: expected=$expected actual=$actual" }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [IO.MemoryStream]::new($bytes, $false)
$zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
try {
    # Validate every name before creating any destination files. Reject drive/ADS,
    # traversal, duplicate names, Windows normalization ambiguities and symlinks.
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName.Replace('\','/')
        if ($name.StartsWith('/') -or $name.Contains(':') -or $name -match '[\x00-\x1f]' -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "Unsafe archive entry: $name" }
        foreach ($segment in $name.TrimEnd('/').Split('/')) {
            if (-not $segment -or $segment -eq '.' -or $segment -eq '..' -or $segment -match '[. ]$' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw "Unsafe archive entry: $name" }
        }
        $out = [IO.Path]::GetFullPath((Join-Path $target $name))
        if (-not $out.StartsWith($target.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase) -or -not $seen.Add($out.TrimEnd('\'))) { throw "Unsafe or duplicate archive entry: $name" }
    }
    New-Item -ItemType Directory -Path $target | Out-Null
    foreach ($entry in $zip.Entries) {
        $out = Join-Path $target $entry.FullName
        if ($entry.FullName.EndsWith('/')) { [IO.Directory]::CreateDirectory($out) | Out-Null }
        else {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($out)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $out, $false)
        }
    }
} finally { $zip.Dispose(); $stream.Dispose() }
$patches = @('Apply-Stable-Hotfix.ps1','Apply-0.3.1-Hotfix.ps1','Apply-0.3.2-Dev.ps1','Apply-0.3.2-Dev3.ps1','Apply-0.3.2-Dev4.ps1','Apply-0.3.2-Dev5.ps1','Apply-0.3.2-Dev6.ps1','Apply-0.3.2-Dev7.ps1','Apply-0.3.2-Final.ps1')
$inputs = @()
foreach ($patch in $patches) {
    $path = Join-Path $media $patch
    $inputs += [ordered]@{ path=$patch; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    $parameters = @{ SourceRoot=$target }
    if ($patch -eq 'Apply-0.3.2-Dev4.ps1') { $parameters.CertificationRoot=$media }
    & $path @parameters
    if (-not $?) { throw "Patch failed: $patch" }
}
foreach ($cert in @('Test-0.3.2-Hardware.ps1','Test-0.3.2-Hardware.cmd')) {
    $inputs += [ordered]@{ path=$cert; sha256=(Get-FileHash -LiteralPath (Join-Path $media $cert) -Algorithm SHA256).Hash }
}
$files = @(Get-ChildItem -LiteralPath $target -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path=$_.FullName.Substring($target.TrimEnd('\').Length+1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash; bytes=$_.Length }
})
[ordered]@{ baseline='0.3.2'; archiveSha256=$actual; patchOrder=$patches; inputs=$inputs; files=$files } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $target 'reconstruction-manifest.json') -Encoding UTF8
Write-Host "Reconstructed verified 0.3.2: $target ($($files.Count) files)"
