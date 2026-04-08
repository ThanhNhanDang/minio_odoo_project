; Inno Setup Script for MinIO Sync
; Build the Flutter app first: flutter build windows --release
; Then compile this script with Inno Setup to create the installer.

#define MyAppName "MinIO Sync"
#define MyAppVersion "1.0.12"
#define MyAppPublisher "AutoNSI"
#define MyAppExeName "minio_sync.exe"
#define MyAppDescription "MinIO Document Sync for Odoo"

; Path to Flutter release build output
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppSupportURL=https://github.com/ThanhNhanDang/minio_odoo_project
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=MinIOSync-{#MyAppVersion}-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\assets\app_icon.ico
; Force-close running app before installing (critical for auto-update)
CloseApplications=force
CloseApplicationsFilter=*.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "launchstartup"; Description: "Launch at Windows startup"; GroupDescription: "Other:"

[Files]
; Main executable
Source: "{#BuildDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; DLLs
Source: "{#BuildDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion

; Config template
Source: "{#BuildDir}\config.json"; DestDir: "{app}"; Flags: onlyifdoesntexist

; Data folder (Flutter assets, ICU, app.so)
Source: "{#BuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

; Registry: auto-startup is managed by the app itself (launchAtStartup package).
; Do NOT touch the registry here — installer must preserve user's existing setting.

[Run]
; Always launch after install — including silent mode (auto-update needs restart)
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall

[UninstallRun]
Filename: "taskkill"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "KillApp"

[Code]
// Kill running app BEFORE files are installed
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    Exec('taskkill', '/F /IM {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    // Small delay to ensure process fully exits and releases file locks
    Sleep(500);
  end;
end;

[UninstallDelete]
Type: files; Name: "{app}\.minio_sync.lock"
Type: files; Name: "{app}\config.json"
