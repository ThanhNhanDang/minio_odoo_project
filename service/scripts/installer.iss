; MinIO Service - Inno Setup Installer Script
; Requires: Inno Setup 6+ (https://jrsoftware.org/isinfo.php)
;
; Usage: build-installer.bat builds the exe then compiles this script.
; Or manually: iscc.exe installer.iss

#define MyAppName "MinIO Service"
#define MyAppPublisher "AutoNSI"
#define MyAppURL "https://github.com/ThanhNhanDang/minio_odoo_project"
#define MyAppExeName "minio-service.exe"

; Version is passed from build-installer.bat via /D flag
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

[Setup]
AppId={{B8E2F4A1-7C3D-4E5F-9A1B-2C3D4E5F6A7B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\AutoNSI\MinIOService
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\release
OutputBaseFilename=MinIO-Service-Setup-v{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\internal\tray\icon.ico
; Close running instance before installing
CloseApplications=force
CloseApplicationsFilter=*.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart"; Description: "Start MinIO Service with Windows"; GroupDescription: "Startup:"

[InstallDelete]
; Clean up .old file from previous auto-updates
Type: files; Name: "{app}\minio-service.exe.old"

[Files]
; Main executable (built by build-installer.bat)
Source: "..\release\minio-service.exe"; DestDir: "{app}"; Flags: ignoreversion; BeforeInstall: StopRunningInstance

; Config template — only install if not already present (don't overwrite user config)
Source: "..\release\config.json"; DestDir: "{app}"; Flags: onlyifdoesntexist

[Icons]
; Start Menu
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

; Desktop shortcut (optional)
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

; Startup folder (optional — auto-start with Windows)
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: autostart

[Run]
; Launch after install
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop the service before uninstall (taskkill, ignore errors)
Filename: "taskkill"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "StopService"

[UninstallDelete]
; Clean up log and old files
Type: files; Name: "{app}\minio-service.log"
Type: files; Name: "{app}\minio-service.exe.old"

[Code]
procedure StopRunningInstance;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM minio-service.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1000); // Wait for process to fully exit and release singleton lock
end;
