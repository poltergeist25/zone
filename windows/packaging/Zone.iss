; Compile after packaging/prepare.py and the PyInstaller onedir build.
; No startup task, service, auto-launch, camera use or profile deletion.
#include "version.iss"

[Setup]
AppId={{9775F2AA-5F2D-4828-9542-7DACD822ACDA}
AppName=Zone
AppVersion={#ZoneVersion}
AppPublisher=Gramercy Systems 212 Inc
DefaultDirName={localappdata}\Programs\Zone
DefaultGroupName=Zone
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir=..\dist
OutputBaseFilename=Zone-{#ZoneVersion}-beta.1-Windows-x64-Setup
LicenseFile=installer-license.txt
SetupIconFile=zone.ico
UninstallDisplayIcon={app}\Zone.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
DisableWelcomePage=no
UninstallDisplayName=Zone
VersionInfoVersion={#ZoneVersion}.0
VersionInfoCompany=Gramercy Systems 212 Inc
VersionInfoProductName=Zone
VersionInfoCopyright=Copyright 2026 Gramercy Systems 212 Inc

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\dist\Zone\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Zone"; Filename: "{app}\Zone.exe"
Name: "{userdesktop}\Zone"; Filename: "{app}\Zone.exe"; Tasks: desktopicon

; Intentionally no [Run] or [UninstallDelete]. Installation does not start
; tracking. Uninstall removes installed files and leaves the local profile.

[Code]
var
  PreparedUpdate: Boolean;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  Existing: String;
begin
  Result := '';
  PreparedUpdate := False;
  Existing := ExpandConstant('{app}\Zone.exe');
  if FileExists(Existing) then begin
    if not Exec(Existing, '--prepare-update {#ZoneExeSHA256}', '', SW_HIDE, ewWaitUntilTerminated, Code) then
      Result := 'Could not ask Zone to release its camera. Close Zone and try again.'
    else if Code = 0 then
      PreparedUpdate := True
    else if Code <> 10 then
      Result := 'Zone did not confirm a safe update. Its files have not been replaced. Close Zone and try again.';
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if (CurStep = ssPostInstall) and PreparedUpdate then begin
    if not Exec(ExpandConstant('{app}\Zone.exe'), '--resume-update', '', SW_SHOWNORMAL, ewNoWait, Code) then
      MsgBox('Zone was updated. Open it from Start to continue; your settings are saved.', mbInformation, MB_OK);
  end;
end;

function InitializeUninstall(): Boolean;
var
  Code: Integer;
begin
  Result := Exec(ExpandConstant('{app}\Zone.exe'), '--prepare-update {#ZoneExeSHA256}', '', SW_HIDE, ewWaitUntilTerminated, Code);
  if Result then Result := (Code = 0) or (Code = 10);
  if not Result then MsgBox('Close Zone before uninstalling so its camera and history can be released safely.', mbError, MB_OK);
end;
