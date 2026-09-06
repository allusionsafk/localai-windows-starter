#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path $root ('.artifacts/reconstruction-safety-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'Reconstruct-0.3.2.ps1') -Destination $fixture
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
    foreach ($entryName in @('../outside.txt','/absolute.txt','C:/drive.txt','safe/file.txt:ads','safe/CON.txt','safe/trailing.')) {
        $memory=[IO.MemoryStream]::new()
        $zip=[IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Create, $true)
        $entry=$zip.CreateEntry($entryName)
        $zip.Dispose()
        $bytes=$memory.ToArray(); $memory.Dispose()
        $sha=[Security.Cryptography.SHA256]::Create()
        $hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-',''); $sha.Dispose()
        Set-Content -LiteralPath (Join-Path $fixture 'AdaptiveMedia-0.3.0-Source.sha256.txt') -Value $hash
        $encoded=[Convert]::ToBase64String($bytes)
        for ($i=0;$i -lt 5;$i++) { $value=''; if ($i -eq 0) { $value=$encoded }; Set-Content -LiteralPath (Join-Path $fixture ('AdaptiveMedia-0.3.0-Source.part{0:00}.b64' -f $i)) -Value $value }
        $destination=Join-Path $fixture 'output'
        try { & (Join-Path $fixture 'Reconstruct-0.3.2.ps1') -Destination $destination; throw 'Unsafe archive accepted' }
        catch { if ($_.Exception.Message -notlike 'Unsafe*archive entry*') { throw } }
        if (Test-Path -LiteralPath $destination) { throw 'Unsafe archive created destination' }
    }
    Set-Content -LiteralPath (Join-Path $fixture 'AdaptiveMedia-0.3.0-Source.sha256.txt') -Value ('0' * 64)
    try { & (Join-Path $fixture 'Reconstruct-0.3.2.ps1') -Destination $destination; throw 'Bad digest accepted' }
    catch { if ($_.Exception.Message -notlike 'Archive SHA-256 mismatch*') { throw } }
    Write-Host 'Reconstruction traversal and hash tests: PASS'
} finally {
    $full=[IO.Path]::GetFullPath($fixture)
    $expected=[IO.Path]::GetFullPath((Join-Path $root '.artifacts')).TrimEnd('\')+'\'
    if (-not $full.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
