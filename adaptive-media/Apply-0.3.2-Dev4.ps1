#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [Parameter(Mandatory = $true)]
    [string]$CertificationRoot
)

$ErrorActionPreference = 'Stop'

function Read-Text([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required source file not found: $Path" }
    return [IO.File]::ReadAllText($Path)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Replace-Exact([string]$Path, [string]$Old, [string]$New, [int]$ExpectedCount = 1) {
    $text = Read-Text $Path
    $count = ([regex]::Matches($text, [regex]::Escape($Old))).Count
    if ($count -ne $ExpectedCount) {
        throw "Expected $ExpectedCount occurrence(s) in $Path, found $count. Needle: $Old"
    }
    Write-Utf8NoBom $Path ($text.Replace($Old, $New))
}

$hardwarePs1 = Join-Path $CertificationRoot 'Test-0.3.2-Hardware.ps1'
$hardwareCmd = Join-Path $CertificationRoot 'Test-0.3.2-Hardware.cmd'
if (-not (Test-Path -LiteralPath $hardwarePs1 -PathType Leaf)) { throw "Hardware certification PS1 missing: $hardwarePs1" }
if (-not (Test-Path -LiteralPath $hardwareCmd -PathType Leaf)) { throw "Hardware certification CMD missing: $hardwareCmd" }

$build  = Join-Path $SourceRoot 'scripts\Build-Dev.ps1'
$iss    = Join-Path $SourceRoot 'installer\AdaptiveMedia.iss'
$proj   = Join-Path $SourceRoot 'src\AdaptiveMedia.App\AdaptiveMedia.App.csproj'
$xaml   = Join-Path $SourceRoot 'src\AdaptiveMedia.App\MainWindow.xaml'
$readme = Join-Path $SourceRoot 'README.md'
$conf   = Join-Path $SourceRoot 'payload\mpv-config\mpv.conf'
$input  = Join-Path $SourceRoot 'payload\mpv-config\input.conf'

# Bundle the already-CI-self-tested hardware gate into this private candidate.
$certDest = Join-Path $SourceRoot 'payload\certification'
Remove-Item -Recurse -Force $certDest -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $certDest | Out-Null
Copy-Item -LiteralPath $hardwarePs1 -Destination (Join-Path $certDest 'Test-0.3.2-Hardware.ps1') -Force
Copy-Item -LiteralPath $hardwareCmd -Destination (Join-Path $certDest 'Test-0.3.2-Hardware.cmd') -Force

# Stage the certification folder with the native app payload.
$stageNeedle = "Copy-Item (Join-Path `$Root 'payload\mpv-config') `$Stage -Recurse"
$stageNew = $stageNeedle + [Environment]::NewLine + "if (Test-Path (Join-Path `$Root 'payload\certification')) { Copy-Item (Join-Path `$Root 'payload\certification') `$Stage -Recurse -Force }"
Replace-Exact $build $stageNeedle $stageNew

# Internal packaging revision only. Product semantics are unchanged from dev3.
Replace-Exact $iss    '#define MyAppVersion "0.3.2-dev3"' '#define MyAppVersion "0.3.2-dev4"'
Replace-Exact $proj   '<InformationalVersion>0.3.2-dev3</InformationalVersion>' '<InformationalVersion>0.3.2-dev4</InformationalVersion>'
Replace-Exact $xaml   'Text="v0.3.2-dev3"' 'Text="v0.3.2-dev4"'
Replace-Exact $readme '# Adaptive Media 0.3.2-dev3' '# Adaptive Media 0.3.2-dev4'
Replace-Exact $readme 'AdaptiveMediaSetup-0.3.2-dev3-x64.exe' 'AdaptiveMediaSetup-0.3.2-dev4-x64.exe'
Replace-Exact $conf   '# Adaptive Media 0.3.2-dev3 - managed mpv defaults' '# Adaptive Media 0.3.2-dev4 - managed mpv defaults'
Replace-Exact $input  '# Adaptive Media 0.3.2-dev3' '# Adaptive Media 0.3.2-dev4'

# Keep a repeatable Start Menu entry when Start Menu integration is selected.
$iconNeedle = 'Name: "{group}\Adaptive Media"; Filename: "{app}\{#MyAppExeName}"; Tasks: startmenu'
$iconNew = $iconNeedle + [Environment]::NewLine + 'Name: "{group}\Adaptive Media 0.3.2 Hardware Certification"; Filename: "{app}\certification\Test-0.3.2-Hardware.cmd"; WorkingDir: "{app}\certification"; Tasks: startmenu'
Replace-Exact $iss $iconNeedle $iconNew

# This is a private hardware-candidate installer: default the completion page to
# the objective certification run. Launching the normal GUI remains available but
# starts unchecked so the two post-install processes do not race each other.
$runNeedle = 'Filename: "{app}\{#MyAppExeName}"; Description: "Launch Adaptive Media"; Flags: nowait postinstall skipifsilent'
$runNew = 'Filename: "{app}\certification\Test-0.3.2-Hardware.cmd"; Description: "Run objective 0.3.2 hardware certification"; Flags: nowait postinstall skipifsilent' + [Environment]::NewLine + 'Filename: "{app}\{#MyAppExeName}"; Description: "Launch Adaptive Media"; Flags: nowait postinstall skipifsilent unchecked'
Replace-Exact $iss $runNeedle $runNew

# Fail closed if the candidate no longer contains exactly the intended plumbing.
$buildText = Read-Text $build
if (([regex]::Matches($buildText, [regex]::Escape("payload\certification"))).Count -ne 2) { throw 'Build staging certification plumbing missing or duplicated.' }

$issText = Read-Text $iss
foreach ($needle in @(
    '#define MyAppVersion "0.3.2-dev4"',
    'Adaptive Media 0.3.2 Hardware Certification',
    'Run objective 0.3.2 hardware certification',
    'Test-0.3.2-Hardware.cmd',
    'Flags: nowait postinstall skipifsilent unchecked'
)) {
    if (-not $issText.Contains($needle)) { throw "Dev4 installer certification integration missing: $needle" }
}
if (([regex]::Matches($issText, 'Run objective 0\.3\.2 hardware certification')).Count -ne 1) { throw 'Hardware certification postinstall entry duplicated.' }

$psCopy = Join-Path $certDest 'Test-0.3.2-Hardware.ps1'
$cmdCopy = Join-Path $certDest 'Test-0.3.2-Hardware.cmd'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $psCopy).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $hardwarePs1).Hash) { throw 'Bundled hardware PS1 does not match reviewed repository copy.' }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $cmdCopy).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $hardwareCmd).Hash) { throw 'Bundled hardware CMD does not match reviewed repository copy.' }

Write-Host 'Adaptive Media 0.3.2-dev4 single-installer hardware-certification packaging applied and verified.'
