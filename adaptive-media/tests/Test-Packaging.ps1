#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Load-Function($path, $name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $node) { throw "Missing tested function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
    return (Get-Item ('Function:' + $name)).ScriptBlock
}
function Assert-Throws($action, $message) { try { & $action } catch { if ($_.Exception.Message -like "*$message*") { return }; throw }; throw "Expected rejection: $message" }
$verify = Load-Function (Join-Path $root 'source/payload/Provision-Dependencies.ps1') 'Assert-DownloadDigest'
Set-Item Function:Assert-DownloadDigest $verify
Assert-Throws { Assert-DownloadDigest ([pscustomobject]@{}) 'missing.exe' } 'SHA-256 digest is required'
Assert-Throws { Assert-DownloadDigest ([pscustomobject]@{digest='sha256:bad'}) 'missing.exe' } 'SHA-256 digest is required'
$sample = Join-Path $root '.artifacts/digest-test.txt'
[IO.File]::WriteAllText($sample, 'download')
try {
    Assert-Throws { Assert-DownloadDigest ([pscustomobject]@{digest=('sha256:' + ('0' * 64))}) $sample } 'did not match'
    Assert-DownloadDigest ([pscustomobject]@{digest=('sha256:' + (Get-FileHash -LiteralPath $sample).Hash)}) $sample
} finally { Remove-Item -LiteralPath $sample }
$guard = Load-Function (Join-Path $root 'source/scripts/Build-Dev.ps1') 'Assert-SafeChild'
Set-Item Function:Assert-SafeChild $guard
Assert-Throws { Assert-SafeChild $root $root } 'outside'
Assert-Throws { Assert-SafeChild (Join-Path $root '../elsewhere') $root } 'outside'
Assert-SafeChild (Join-Path $root '.artifacts/new') $root | Out-Null
Write-Host 'Packaging safety tests: PASS'
