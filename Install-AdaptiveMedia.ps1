#requires -Version 5.1
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$payload = Join-Path $PSScriptRoot 'payload'
if (-not (Test-Path (Join-Path $payload 'AdaptiveMedia.ps1'))) {
    [System.Windows.Forms.MessageBox]::Show('The installer payload is incomplete. Extract the whole ZIP before running setup.', 'Adaptive Media Setup', 'OK', 'Error') | Out-Null
    exit 2
}

$installDir = Join-Path $env:LOCALAPPDATA 'Adaptive Media'
$toolsDir = Join-Path $installDir 'tools'
$iconPath = Join-Path $installDir 'AdaptiveMedia.ico'

function Find-Mpv {
    $cmd = Get-Command mpv.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\mpv\mpv.exe'),
        (Join-Path $env:LOCALAPPDATA 'mpv\mpv.exe'),
        (Join-Path $env:ProgramFiles 'mpv\mpv.exe')
    )) { if ($p -and (Test-Path $p)) { return $p } }
    try {
        $found = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs') -Filter mpv.exe -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    } catch {}
    return $null
}

function Find-YtDlp {
    $cmd = Get-Command yt-dlp.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Join-Path $toolsDir 'yt-dlp.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Find-MpcBe {
    $cmd = Get-Command mpc-be64.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'MPC-BE x64\mpc-be64.exe'),
        (Join-Path $env:ProgramFiles 'MPC-BE\mpc-be64.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\MPC-BE x64\mpc-be64.exe')
    )) { if (Test-Path $p) { return $p } }
    return $null
}

function Invoke-WingetInstall([string]$Id) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }
    $p = Start-Process -FilePath $winget.Source -ArgumentList @(
        'install','--id',$Id,'-e','--source','winget',
        '--accept-package-agreements','--accept-source-agreements','--disable-interactivity'
    ) -Wait -PassThru -WindowStyle Hidden
    return ($p.ExitCode -eq 0)
}

function Download-GitHubAsset($Asset,[string]$Destination) {
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent'='Adaptive-Media-Setup/0.1' }
    if ($Asset.PSObject.Properties['digest'] -and [string]$Asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expected = $Matches[1].ToLowerInvariant()
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw 'SHA-256 verification failed. The downloaded installer was deleted and not executed.'
        }
        return $true
    }
    return $false
}

function Create-Shortcut([string]$Path,[string]$Name,[string]$Arguments) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($Path)
    $s.TargetPath = 'powershell.exe'
    $s.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $installDir 'AdaptiveMedia.ps1') + '"' + $Arguments
    $s.WorkingDirectory = $installDir
    if (Test-Path $iconPath) { $s.IconLocation = $iconPath + ',0' }
    $s.Description = $Name
    $s.Save()
}

function Register-Integration($DesktopShortcut,$StartMenu,$ContextMenu) {
    if ($DesktopShortcut) {
        Create-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Adaptive Media.lnk') 'Adaptive Media' ''
    }
    if ($StartMenu) {
        $folder = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\Adaptive Media'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Create-Shortcut (Join-Path $folder 'Adaptive Media.lnk') 'Adaptive Media' ''

        $ws = New-Object -ComObject WScript.Shell
        $u = $ws.CreateShortcut((Join-Path $folder 'Uninstall Adaptive Media.lnk'))
        $u.TargetPath = 'powershell.exe'
        $u.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $installDir 'Uninstall-AdaptiveMedia.ps1') + '"'
        $u.WorkingDirectory = $installDir
        if (Test-Path $iconPath) { $u.IconLocation = $iconPath + ',0' }
        $u.Save()
    }
    if ($ContextMenu) {
        $video = 'HKCU:\Software\Classes\SystemFileAssociations\video\shell\AdaptiveMedia'
        $folder = 'HKCU:\Software\Classes\Directory\shell\AdaptiveMedia'
        New-Item -Force -Path $video | Out-Null
        Set-Item -LiteralPath $video -Value 'Play with Adaptive Media'
        New-ItemProperty -Path $video -Name 'Icon' -Value $iconPath -PropertyType String -Force | Out-Null
        New-Item -Force -Path (Join-Path $video 'command') | Out-Null
        Set-Item -LiteralPath (Join-Path $video 'command') -Value ('powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $installDir 'AdaptiveMedia.ps1') + '" "%1"')

        New-Item -Force -Path $folder | Out-Null
        Set-Item -LiteralPath $folder -Value 'Play folder with Adaptive Media'
        New-ItemProperty -Path $folder -Name 'Icon' -Value $iconPath -PropertyType String -Force | Out-Null
        New-Item -Force -Path (Join-Path $folder 'command') | Out-Null
        Set-Item -LiteralPath (Join-Path $folder 'command') -Value ('powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $installDir 'AdaptiveMedia.ps1') + '" "%1"')
    }

    $uninstall = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AdaptiveMedia'
    New-Item -Force -Path $uninstall | Out-Null
    New-ItemProperty -Path $uninstall -Name DisplayName -Value 'Adaptive Media' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstall -Name DisplayVersion -Value '0.1.0' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstall -Name Publisher -Value 'Adaptive Media project' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstall -Name InstallLocation -Value $installDir -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstall -Name UninstallString -Value ('powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installDir 'Uninstall-AdaptiveMedia.ps1') + '"') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstall -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstall -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
}

# -------- GUI --------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Adaptive Media Setup'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(720,640)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(244,246,249)
$form.Font = New-Object System.Drawing.Font('Segoe UI',10)

$hero = New-Object System.Windows.Forms.Panel
$hero.Location = New-Object System.Drawing.Point(0,0); $hero.Size = New-Object System.Drawing.Size(720,105); $hero.BackColor = [System.Drawing.Color]::FromArgb(30,34,42); $form.Controls.Add($hero)
$t = New-Object System.Windows.Forms.Label
$t.Text = 'Adaptive Media'; $t.ForeColor = [System.Drawing.Color]::White; $t.Font = New-Object System.Drawing.Font('Segoe UI Semibold',22); $t.Location = New-Object System.Drawing.Point(24,18); $t.AutoSize=$true; $hero.Controls.Add($t)
$st = New-Object System.Windows.Forms.Label
$st.Text = 'Reference-first MPV playback with a friendly Windows launcher.'; $st.ForeColor=[System.Drawing.Color]::Gainsboro; $st.Location=New-Object System.Drawing.Point(28,65); $st.AutoSize=$true; $hero.Controls.Add($st)

$intro = New-Object System.Windows.Forms.Label
$intro.Text = "Installs per-user only. It does not disable Defender, install codec packs, change firewall rules, or require administrator rights. Existing MPV configuration is left untouched because Adaptive Media uses its own isolated config directory."
$intro.Location = New-Object System.Drawing.Point(24,125); $intro.Size = New-Object System.Drawing.Size(670,68); $intro.ForeColor=[System.Drawing.Color]::FromArgb(65,70,78); $form.Controls.Add($intro)

$features = New-Object System.Windows.Forms.GroupBox
$features.Text='Components and Windows integration'; $features.Location=New-Object System.Drawing.Point(24,205); $features.Size=New-Object System.Drawing.Size(670,205); $form.Controls.Add($features)
function Add-Check([string]$Text,[int]$Y,[bool]$Checked=$true) {
    $c=New-Object System.Windows.Forms.CheckBox; $c.Text=$Text; $c.Location=New-Object System.Drawing.Point(18,$Y); $c.Size=New-Object System.Drawing.Size(625,28); $c.Checked=$Checked; $features.Controls.Add($c); return $c
}
$yt = Add-Check 'URL / streaming support with yt-dlp' 28 $true
$mpc = Add-Check 'Install MPC-BE as an optional compatibility fallback' 61 $true
$desk = Add-Check 'Create a Desktop shortcut' 94 $true
$start = Add-Check 'Create Start Menu shortcuts' 127 $true
$ctx = Add-Check 'Add "Play with Adaptive Media" to video/folder context menus' 160 $true

$locationLabel = New-Object System.Windows.Forms.Label
$locationLabel.Text='Install location'; $locationLabel.Location=New-Object System.Drawing.Point(24,425); $locationLabel.AutoSize=$true; $form.Controls.Add($locationLabel)
$location = New-Object System.Windows.Forms.TextBox
$location.Text=$installDir; $location.Location=New-Object System.Drawing.Point(125,420); $location.Size=New-Object System.Drawing.Size(569,28); $location.ReadOnly=$true; $form.Controls.Add($location)

$log = New-Object System.Windows.Forms.TextBox
$log.Location=New-Object System.Drawing.Point(24,465); $log.Size=New-Object System.Drawing.Size(670,110); $log.Multiline=$true; $log.ScrollBars='Vertical'; $log.ReadOnly=$true; $log.BackColor=[System.Drawing.Color]::White; $form.Controls.Add($log)
function Log([string]$Text) { $log.AppendText($Text + "`r`n"); $log.SelectionStart=$log.TextLength; $log.ScrollToCaret(); [System.Windows.Forms.Application]::DoEvents() }

$script:InstallComplete = $false
$install = New-Object System.Windows.Forms.Button
$install.Text='Install'; $install.Location=New-Object System.Drawing.Point(594,590); $install.Size=New-Object System.Drawing.Size(100,34); $install.Font=New-Object System.Drawing.Font('Segoe UI Semibold',10); $form.Controls.Add($install)
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text='Cancel'; $cancel.Location=New-Object System.Drawing.Point(484,590); $cancel.Size=New-Object System.Drawing.Size(100,34); $form.Controls.Add($cancel)
$cancel.Add_Click({ $form.Close() })

$install.Add_Click({
    if ($script:InstallComplete) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $installDir 'AdaptiveMedia.ps1') + '"') | Out-Null
        $form.Close()
        return
    }
    $install.Enabled=$false; $cancel.Enabled=$false
    try {
        if (-not [Environment]::Is64BitOperatingSystem) { throw 'Adaptive Media v0.1 requires 64-bit Windows.' }
        Log 'Preparing per-user installation...'
        New-Item -ItemType Directory -Force -Path $installDir,$toolsDir | Out-Null
        Copy-Item -Path (Join-Path $payload '*') -Destination $installDir -Recurse -Force

        $mpvBefore = Find-Mpv
        $installedMpv = $false
        $mpvPath = $mpvBefore
        if ($mpvPath) {
            Log ('Using existing MPV: ' + $mpvPath)
        } else {
            Log 'Fetching the latest stable mpv-distributions Windows installer metadata...'
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/mpv-distributions/mpv-windows-setup/releases/latest' -Headers @{ 'User-Agent'='Adaptive-Media-Setup/0.1' }
            $asset = $release.assets | Where-Object { $_.name -match '^mpv-setup-x86_64-[0-9].*\.exe$' } | Select-Object -First 1
            if (-not $asset) { throw 'The current MPV release did not contain a standard x86_64 Windows setup asset.' }
            $tmp = Join-Path $env:TEMP $asset.name
            $verified = Download-GitHubAsset $asset $tmp
            Log $(if ($verified) { 'MPV installer SHA-256 verified against GitHub release metadata.' } else { 'MPV release did not expose a digest; download came directly from the project GitHub release over TLS.' })
            Log ('Installing MPV ' + $release.tag_name + ' for the current user...')
            $p = Start-Process -FilePath $tmp -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /TASKS="autoupdate,addtopath"' -Wait -PassThru
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            if ($p.ExitCode -ne 0) { throw ('MPV installer exited with code ' + $p.ExitCode) }
            Start-Sleep -Seconds 1
            $mpvPath = Find-Mpv
            if (-not $mpvPath) { throw 'MPV installed, but mpv.exe could not be located.' }
            $installedMpv = $true
            Log ('MPV installed: ' + $mpvPath)
        }

        $ytBefore = Find-YtDlp
        $installedYt = $false
        if ($yt.Checked) {
            if ($ytBefore) { Log ('Using existing yt-dlp: ' + $ytBefore) }
            else {
                Log 'Installing yt-dlp for URL playback...'
                if (Invoke-WingetInstall 'yt-dlp.yt-dlp') {
                    $installedYt=$true; Log 'yt-dlp installed with Windows Package Manager.'
                } else {
                    Log 'WinGet was unavailable or failed; using the official yt-dlp GitHub release fallback.'
                    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest' -Headers @{ 'User-Agent'='Adaptive-Media-Setup/0.1' }
                    $a = $rel.assets | Where-Object { $_.name -eq 'yt-dlp.exe' } | Select-Object -First 1
                    if (-not $a) { throw 'yt-dlp release did not contain yt-dlp.exe.' }
                    $yp = Join-Path $toolsDir 'yt-dlp.exe'
                    $verified = Download-GitHubAsset $a $yp
                    Log $(if ($verified) { 'yt-dlp SHA-256 verified against GitHub release metadata.' } else { 'yt-dlp downloaded from its official GitHub release over TLS; release metadata did not expose a digest.' })
                    $installedYt=$true
                }
            }
        }

        $mpcBefore = Find-MpcBe
        $installedMpc = $false
        if ($mpc.Checked) {
            if ($mpcBefore) { Log ('Using existing MPC-BE: ' + $mpcBefore) }
            else {
                Log 'Installing MPC-BE compatibility player through WinGet...'
                if (Invoke-WingetInstall 'MPC-BE.MPC-BE') { $installedMpc=$true; Log 'MPC-BE installed.' }
                else { Log 'MPC-BE could not be installed automatically. Adaptive Media will continue without the fallback player.' }
            }
        }

        $state = [pscustomobject]@{
            version='0.1.0'; installed=(Get-Date).ToString('o'); mpvPath=$mpvPath
            mpvInstalledBySetup=$installedMpv; ytDlpInstalledBySetup=$installedYt; mpcBeInstalledBySetup=$installedMpc
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installDir 'state.json') -Encoding UTF8
        if (-not (Test-Path (Join-Path $installDir 'settings.json'))) {
            [pscustomobject]@{Profile='Automatic';AutoHdrSwitch=$true;PreferExternalDisplay=$true;FullscreenExternal=$true;HdmiBitstream=$false;MpcFallback=$true} |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installDir 'settings.json') -Encoding UTF8
        }

        Register-Integration $desk.Checked $start.Checked $ctx.Checked
        Log 'Windows shortcuts, uninstall entry and selected context-menu integration created.'

        $ver = (& $mpvPath --no-config --version | Select-Object -First 1) -join ''
        Log ('Sanity check: ' + $ver)
        Log 'Installation complete.'

        $script:InstallComplete=$true
        $install.Text='Launch'; $install.Enabled=$true; $cancel.Text='Close'; $cancel.Enabled=$true
        [System.Windows.Forms.MessageBox]::Show('Adaptive Media is installed. Use the Desktop or Start Menu shortcut, right-click supported video files/folders, drag media onto the app, or paste a URL inside the launcher.', 'Adaptive Media Setup', 'OK', 'Information') | Out-Null
    } catch {
        Log ('ERROR: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Adaptive Media Setup', 'OK', 'Error') | Out-Null
        $install.Enabled=$true; $cancel.Enabled=$true
    }
})

[void][System.Windows.Forms.Application]::Run($form)
