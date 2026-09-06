#define MyAppName "Adaptive Media Preview"
#define MyAppVersion "0.4.0-rc1"
#define MyAppPublisher "Adaptive Media"
#define MyAppExeName "AdaptiveMedia.exe"

[Setup]
AppId={{C7A97DB2-4037-48ED-873D-2305244D2E41}
AppName={#MyAppName}
AppVerName={#MyAppName} {#MyAppVersion}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Adaptive Media Preview
DefaultGroupName=Adaptive Media Preview
UsePreviousAppDir=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=AdaptiveMediaSetup-{#MyAppVersion}-x64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\src\AdaptiveMedia.App\Assets\AdaptiveMedia.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
VersionInfoVersion=0.4.0.0
VersionInfoCompany=Adaptive Media
VersionInfoDescription=Adaptive Media installer
VersionInfoProductName=Adaptive Media
VersionInfoProductVersion=0.4.0.0

[Tasks]
Name: "deps"; Description: "Install or repair MPV (recommended)"; GroupDescription: "Playback components:"; Flags: checkedonce
Name: "ytdlp"; Description: "Install yt-dlp for URL/stream playback"; GroupDescription: "Playback components:"; Flags: checkedonce
Name: "mpcbe"; Description: "Install MPC-BE as a compatibility fallback"; GroupDescription: "Playback components:"; Flags: checkedonce
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Windows integration:"; Flags: checkedonce
Name: "startmenu"; Description: "Create Start Menu shortcut"; GroupDescription: "Windows integration:"; Flags: checkedonce
Name: "contextmenu"; Description: "Add Play with Adaptive Media to video/folder context menus"; GroupDescription: "Windows integration:"; Flags: checkedonce

[Files]
Source: "..\build\staging\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Adaptive Media Preview"; Filename: "{app}\{#MyAppExeName}"; Tasks: startmenu
Name: "{group}\Adaptive Media Playback Diagnostics"; Filename: "{app}\{#MyAppExeName}"; Parameters: "--diagnostics"; WorkingDir: "{app}"; Tasks: startmenu
Name: "{autodesktop}\Adaptive Media Preview"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\video\shell\AdaptiveMediaPreviewLegacy"; Flags: deletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\AdaptiveMediaPreviewLegacy"; Flags: deletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\video\shell\AdaptiveMediaPreview"; ValueType: string; ValueName: ""; ValueData: "Play with Adaptive Media Preview"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\video\shell\AdaptiveMediaPreview"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\{#MyAppExeName}"; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\video\shell\AdaptiveMediaPreview\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\AdaptiveMediaPreview"; ValueType: string; ValueName: ""; ValueData: "Play folder with Adaptive Media Preview"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\AdaptiveMediaPreview"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\{#MyAppExeName}"; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\AdaptiveMediaPreview\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Tasks: contextmenu

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Provision-Dependencies.ps1"" -Mpv"; StatusMsg: "Installing or checking MPV..."; Flags: runhidden waituntilterminated; Tasks: deps
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Provision-Dependencies.ps1"" -YtDlp"; StatusMsg: "Installing or checking yt-dlp..."; Flags: runhidden waituntilterminated; Tasks: ytdlp
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Provision-Dependencies.ps1"" -MpcBe"; StatusMsg: "Installing or checking MPC-BE..."; Flags: runhidden waituntilterminated; Tasks: mpcbe
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Adaptive Media"; Flags: nowait postinstall skipifsilent
