#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$InstallTools,
    [switch]$SmokeTest,
    [switch]$Clean
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Build = Join-Path $Root 'build'
$Stage = Join-Path $Build 'staging'
$Dist = Join-Path $Root 'dist'
$Project = Join-Path $Root 'src\AdaptiveMedia.App\AdaptiveMedia.App.csproj'
$Iss = Join-Path $Root 'installer\AdaptiveMedia.iss'
# The installer script is the single source of truth for the product version.
$VersionMatch = [regex]::Match([IO.File]::ReadAllText($Iss), '(?m)^#define\s+MyAppVersion\s+"([^"]+)"\s*$')
if (-not $VersionMatch.Success) { throw "Could not read MyAppVersion from $Iss." }
$Version = $VersionMatch.Groups[1].Value

function Step([string]$s) { Write-Host "`n==> $s" -ForegroundColor Cyan }
function Require-Winget { if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'WinGet is required for -InstallTools. Install App Installer from Microsoft first.' } }

function Assert-SafeChild([string]$Path, [string]$Parent) {
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $full.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside intended directory: $full" }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not a safe cleanup target: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}
function Remove-SafeChild([string]$Path, [string]$Parent) {
    $checked = Assert-SafeChild $Path $Parent
    if (Test-Path -LiteralPath $checked) { Remove-Item -LiteralPath $checked -Recurse -Force }
}
if ($Clean) { Remove-SafeChild $Build $Root; Remove-SafeChild $Dist $Root }
New-Item -ItemType Directory -Force -Path $Stage,$Dist | Out-Null

function Get-Dotnet10Sdk {
    $cmd = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $sdks = @(& $cmd.Source --list-sdks 2>$null)
    if (@($sdks | Where-Object { $_ -match '^10\.\d+\.\d+' }).Count -eq 0) { return $null }
    return $cmd
}

$dotnet = Get-Dotnet10Sdk
if (-not $dotnet -and $InstallTools) {
    Step 'Installing .NET 10 SDK'
    Require-Winget
    winget install --id Microsoft.DotNet.SDK.10 -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw '.NET 10 SDK installation failed.' }
    $dotnet = Get-Dotnet10Sdk
}
if (-not $dotnet) { throw '.NET 10 SDK not found. A dotnet runtime alone is not sufficient. Run again with -InstallTools or install Microsoft.DotNet.SDK.10.' }

$isccCandidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    "$env:ProgramFiles\Inno Setup 7\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) }
$iscc = $isccCandidates | Select-Object -First 1
if (-not $iscc -and $InstallTools) {
    Step 'Installing Inno Setup'
    Require-Winget
    winget install --id JRSoftware.InnoSetup.7 -e --source winget --accept-package-agreements --accept-source-agreements
    $iscc = @(
        "$env:ProgramFiles\Inno Setup 7\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw 'ISCC.exe not found. Run again with -InstallTools or install JRSoftware.InnoSetup.7 (or Inno Setup 6).' }

Step 'Publishing native WPF Adaptive Media EXE'
& $dotnet.Source publish $Project -c Release -r win-x64 --self-contained true -o (Join-Path $Build 'app')
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

Step 'Staging installer payload'
Remove-SafeChild $Stage $Root
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Copy-Item (Join-Path $Build 'app\*') $Stage -Recurse -Force
Copy-Item (Join-Path $Root 'payload\AdaptiveMedia.Engine.ps1') $Stage
Copy-Item (Join-Path $Root 'payload\Provision-Dependencies.ps1') $Stage
Copy-Item (Join-Path $Root 'payload\AdaptiveMedia.ico') $Stage
Copy-Item (Join-Path $Root 'payload\mpv-config') $Stage -Recurse
if (Test-Path (Join-Path $Root 'payload\certification')) { Copy-Item (Join-Path $Root 'payload\certification') $Stage -Recurse -Force }

Step 'Launcher self-test'
$stageLauncher = Join-Path $Stage 'AdaptiveMedia.exe'
$selfTest = Start-Process -FilePath $stageLauncher -ArgumentList '--self-test' -Wait -PassThru -WindowStyle Hidden
if ($selfTest.ExitCode -ne 0) { throw "Native app self-test failed with exit code $($selfTest.ExitCode)." }
Write-Host 'Native app self-test: PASS' -ForegroundColor Green

$integrationTest = Start-Process -FilePath $stageLauncher -ArgumentList '--integration-test' -Wait -PassThru -WindowStyle Hidden
if ($integrationTest.ExitCode -ne 0) { throw "Native app integration test failed with exit code $($integrationTest.ExitCode)." }
Write-Host 'GUI/backend/engine launch-plan integration: PASS' -ForegroundColor Green

if ($SmokeTest) {
    Step 'Safe isolated installer smoke test using a dedicated smoke AppId'
    $smokeIss = Join-Path (Split-Path -Parent $Iss) 'AdaptiveMedia.Smoke.generated.iss'
    $smokeDist = Join-Path $Build 'smoke-dist'
    $smoke = $null
    Remove-SafeChild $smokeDist $Root
    New-Item -ItemType Directory -Force -Path $smokeDist | Out-Null
    try {
        $issText = [IO.File]::ReadAllText($Iss)
        if (([regex]::Matches($issText, '(?m)^AppId=\{\{C7A97DB2-4037-48ED-873D-2305244D2E41\}\r?$')).Count -ne 1) { throw 'Cannot safely substitute the smoke AppId.' }
        $issText = $issText.Replace('AppId={{C7A97DB2-4037-48ED-873D-2305244D2E41}', ('AppId={{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'))
        $issText = $issText.Replace('OutputDir=..\dist', 'OutputDir=..\build\smoke-dist')
        $issText = $issText.Replace('OutputBaseFilename=AdaptiveMediaSetup-{#MyAppVersion}-x64', 'OutputBaseFilename=AdaptiveMediaSetup-Smoke-x64')
        $issText = [regex]::Replace($issText, '(?ms)^\[Registry\].*?(?=^\[Run\])', '')
        if ($issText -match '(?m)^\[(Registry|InstallDelete)\]') { throw 'Smoke installer still contains user integration mutations.' }
        [IO.File]::WriteAllText($smokeIss, $issText, [Text.UTF8Encoding]::new($false))

        & $iscc /Qp $smokeIss
        if ($LASTEXITCODE -ne 0) { throw 'Smoke installer compilation failed.' }
        $smokeSetup = Join-Path $smokeDist 'AdaptiveMediaSetup-Smoke-x64.exe'
        if (-not (Test-Path -LiteralPath $smokeSetup)) { throw 'Smoke installer EXE was not created.' }

        $smoke = Join-Path $env:TEMP ('AdaptiveMedia-Smoke-' + [guid]::NewGuid().ToString('N'))
        $nativeArgs = @(
            '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',
            ('/DIR="' + $smoke + '"'),
            '/TASKS="!deps,!ytdlp,!mpcbe,!desktopicon,!startmenu,!contextmenu"'
        )
        $p = Start-Process -FilePath $smokeSetup -ArgumentList $nativeArgs -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw "Installer smoke install failed with exit code $($p.ExitCode)." }
        $smokeLauncher = Join-Path $smoke 'AdaptiveMedia.exe'
        if (-not (Test-Path $smokeLauncher)) { throw 'Smoke install did not create AdaptiveMedia.exe.' }
        if (-not (Test-Path -LiteralPath (Join-Path $smoke 'mpv-config\runtime\adaptive-playback.lua'))) { throw 'Installed runtime script missing.' }

        $installedSelfTest = Start-Process -FilePath $smokeLauncher -ArgumentList '--self-test' -Wait -PassThru -WindowStyle Hidden
        if ($installedSelfTest.ExitCode -ne 0) { throw "Installed app self-test failed with exit code $($installedSelfTest.ExitCode)." }
        $installedIntegration = Start-Process -FilePath $smokeLauncher -ArgumentList '--integration-test' -Wait -PassThru -WindowStyle Hidden
        if ($installedIntegration.ExitCode -ne 0) { throw "Installed app integration test failed with exit code $($installedIntegration.ExitCode)." }

        $settingsSentinel = Join-Path $smoke 'settings.json'
        [IO.File]::WriteAllText($settingsSentinel, '{"packagingSmoke":"preserve"}')
        $settingsHash = (Get-FileHash -LiteralPath $settingsSentinel).Hash
        $upgrade = Start-Process -FilePath $smokeSetup -ArgumentList $nativeArgs -Wait -PassThru -WindowStyle Hidden
        if ($upgrade.ExitCode -ne 0) { throw "Smoke upgrade failed: $($upgrade.ExitCode)" }
        if ((Get-FileHash -LiteralPath $settingsSentinel).Hash -ne $settingsHash) { throw 'Upgrade changed settings sentinel.' }
        $uninstaller = Get-ChildItem $smoke -Filter 'unins*.exe' | Select-Object -First 1
        if (-not $uninstaller) { throw 'Smoke install did not create an uninstaller.' }
        $u = Start-Process -FilePath $uninstaller.FullName -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru -WindowStyle Hidden
        if ($u.ExitCode -ne 0) { throw "Smoke uninstall failed with exit code $($u.ExitCode)." }
        if (Test-Path -LiteralPath $smokeLauncher) { throw 'Uninstall left the application executable.' }
        if ((Get-FileHash -LiteralPath $settingsSentinel).Hash -ne $settingsHash) { throw 'Uninstall changed settings sentinel.' }
        Write-Host 'Installer install/upgrade/self-test/integration-test/uninstall/settings preservation: PASS' -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $smokeIss -Force -ErrorAction SilentlyContinue
        Remove-SafeChild $smokeDist $Root
        if ($smoke -and (Test-Path -LiteralPath $smoke)) {
            # On any failed assertion, unregister the isolated install before cleanup.
            $remaining = Get-ChildItem -LiteralPath $smoke -Filter 'unins*.exe' | Select-Object -First 1
            if ($remaining) {
                $cleanup = Start-Process -FilePath $remaining.FullName -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru -WindowStyle Hidden
                if ($cleanup.ExitCode -ne 0) { throw "Smoke cleanup uninstall failed; preserved directory: $smoke" }
            }
            Remove-SafeChild $smoke $env:TEMP
        }
    }
}

Step 'Compiling development Inno Setup installer EXE'
& $iscc /Qp $Iss
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compiler failed.' }
$setupPath = Join-Path $Dist ('AdaptiveMediaSetup-' + $Version + '-x64.exe')
$setup = Get-Item -LiteralPath $setupPath -ErrorAction Stop
if (-not $setup) { throw 'Installer EXE was not created.' }

Write-Host "Launcher: $(Join-Path $Stage 'AdaptiveMedia.exe')" -ForegroundColor Green
Write-Host "Installer: $($setup.FullName)" -ForegroundColor Green
Write-Host "Installer SHA-256: $((Get-FileHash -Algorithm SHA256 $setup.FullName).Hash)" -ForegroundColor Green


$artifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup.FullName).Hash
$checksumPath = [IO.Path]::ChangeExtension($setup.FullName, 'sha256.txt')
[IO.File]::WriteAllText($checksumPath, ($artifactHash + '  ' + $setup.Name + [Environment]::NewLine), [Text.Encoding]::ASCII)
[ordered]@{ version=$Version; installer=$setup.Name; sha256=$artifactHash; bytes=$setup.Length; builtUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Dist 'build-provenance.json') -Encoding UTF8
