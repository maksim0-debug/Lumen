; Script generated for Inno Setup 6
; Application: Lumen - Power Outage Monitor
; Platform: Windows x64

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#ifndef MyAppSourceDir
  #define MyAppSourceDir "..\..\Lumen"
#endif

#define MyAppName "Lumen"
#define MyAppPublisher "maksim0-debug"
#define MyAppURL "https://github.com/maksim0-debug/vikl"
#define MyAppExeName "Lumen.exe"

[Setup]
; Unique App ID for uninstallation and updates
AppId={{D37F2C0B-97F1-4F42-9AE4-51CE564A1982}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases

; Default Installation Directory and Privileges
; PrivilegesRequiredOverridesAllowed=dialog allows user to select Current User or All Users
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; Output Configuration
OutputDir=..\..\artifacts
OutputBaseFilename=Lumen-Windows-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

; Compression & Modern Wizard
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

; 64-bit Architecture
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Handle running instance gracefully
CloseApplications=yes
AppMutex=Lumen_App_Mutex_maksim0

[Languages]
Name: "ukrainian"; MessagesFile: "compiler:Languages\Ukrainian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyAppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; AppUserModelID: "Maksim0Debug.Lumen.App"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; AppUserModelID: "Maksim0Debug.Lumen.App"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent runasoriginaluser
