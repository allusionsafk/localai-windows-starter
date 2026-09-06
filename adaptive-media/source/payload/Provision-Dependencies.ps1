#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Mpv,
    [switch]$YtDlp,
    [switch]$MpcBe
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Log = Join-Path $InstallDir 'provision.log'

function Write-Log([string]$Message) {
    ('{0}  {1}' -f (Get-Date).ToString('s'), $Message) | Add-Content -LiteralPath $Log -Encoding UTF8
}

function Find-Mpv {
    $cmd = Get-Command mpv.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        'C:\mpv\mpv.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\mpv\mpv.exe'),
        (Join-Path $env:LOCALAPPDATA 'mpv\mpv.exe'),
        (Join-Path $env:ProgramFiles 'mpv\mpv.exe')
    )) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Invoke-WingetInstall([string]$Id, [string]$Action = 'install') {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }
    Write-Log "WinGet ${Action}: $Id"
    $capture = Join-Path $env:TEMP ('AdaptiveMedia-Winget-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $capture | Out-Null
    try {
    $p = Start-Process -FilePath $winget.Source -ArgumentList @(
        $Action,'--id',$Id,'-e','--source','winget',
        '--accept-package-agreements','--accept-source-agreements','--disable-interactivity'
    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $capture 'stdout.log') -RedirectStandardError (Join-Path $capture 'stderr.log')
    Write-Log ('WinGet exit code: ' + $p.ExitCode)
    foreach ($file in @('stdout.log','stderr.log')) {
        $path = Join-Path $capture $file
        if (Test-Path -LiteralPath $path) { Write-Log ([IO.File]::ReadAllText($path)) }
    }
    return ($p.ExitCode -eq 0)
    } finally {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($capture)) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) { throw 'Unsafe capture cleanup path.' }
        Remove-Item -LiteralPath $capture -Recurse -Force
    }
}

function Assert-DownloadDigest($Asset, [string]$Path) {
    if (-not $Asset.PSObject.Properties['digest'] -or [string]$Asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw 'A valid MPV setup SHA-256 digest is required; no installer was executed.'
    }
    $expected = $Matches[1]
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash -ne $expected) {
        throw 'MPV setup SHA-256 did not match GitHub release metadata.'
    }
}

function Install-Mpv {
    $existing = Find-Mpv
    if ($existing) {
        Write-Log "MPV already present: $existing"
        return
    }

    Write-Log 'Fetching latest stable mpv-distributions release metadata.'
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/mpv-distributions/mpv-windows-setup/releases/latest' -Headers @{ 'User-Agent'='Adaptive-Media-DevKit/0.3' }
    $asset = $release.assets | Where-Object { $_.name -match '^mpv-setup-x86_64-[0-9].*\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw 'No standard x86_64 MPV setup asset was found in the latest stable release.' }

    if (-not $asset.PSObject.Properties['digest'] -or [string]$asset.digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw 'A valid MPV setup SHA-256 digest is required; no installer was executed.'
    }
    $scratch = Join-Path $env:TEMP ('AdaptiveMedia-Provision-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
    $tmp = Join-Path $scratch 'mpv-setup.exe'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing -Headers @{ 'User-Agent'='Adaptive-Media-DevKit/0.3' }

    Assert-DownloadDigest $asset $tmp
    $p = Start-Process -FilePath $tmp -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /TASKS="autoupdate,addtopath"' -Wait -PassThru -WindowStyle Hidden
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "MPV setup exited with code $($p.ExitCode)." }
    Write-Log "Installed MPV release $($release.tag_name)."
    } finally {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($scratch)) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) { throw 'Unsafe provision cleanup path.' }
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}

try {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    if ($Mpv) { Install-Mpv }
    if ($YtDlp) {
        if (Get-Command yt-dlp.exe -ErrorAction SilentlyContinue) {
            # Site extractors change constantly, so a yt-dlp left at an old build
            # stops resolving URLs. Refresh it, but never fail setup when there is
            # nothing to upgrade or WinGet is unavailable.
            if (Invoke-WingetInstall 'yt-dlp.yt-dlp' 'upgrade') { Write-Log 'yt-dlp upgraded.' }
            else { Write-Log 'yt-dlp is present; no upgrade was applied.' }
        }
        elseif (-not (Invoke-WingetInstall 'yt-dlp.yt-dlp')) { throw 'yt-dlp WinGet installation failed.' }
    }
    if ($MpcBe) {
        if (Get-Command mpc-be64.exe -ErrorAction SilentlyContinue) { Write-Log 'MPC-BE already present.' }
        elseif (-not (Invoke-WingetInstall 'MPC-BE.MPC-BE')) { throw 'MPC-BE WinGet installation failed.' }
    }
    exit 0
}
catch {
    $failure = $_.Exception.Message
    try { Write-Log ('ERROR: ' + $failure) } catch { }
    try {
        Add-Type -AssemblyName PresentationFramework
        [Windows.MessageBox]::Show(("Playback component setup failed: " + $failure + [Environment]::NewLine + "Details: " + $Log + [Environment]::NewLine + 'Rerun setup to repair components.'), 'Adaptive Media setup', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}
