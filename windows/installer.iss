#define AppName "Quick Transfer"
#ifndef AppVersion
  #error "Pass /DAppVersion=<version> to ISCC"
#endif
#ifndef SourceDir
  #error "Pass /DSourceDir=<absolute build bundle path> to ISCC"
#endif
#ifndef OutputDir
  #error "Pass /DOutputDir=<absolute output path> to ISCC"
#endif

[Setup]
AppId={{F2D61F05-7B76-4652-BD3D-8E89DC97A411}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Quick Transfer
DefaultDirName={localappdata}\Programs\Quick Transfer
DefaultGroupName=Quick Transfer
OutputDir={#OutputDir}
OutputBaseFilename=quick-transfer_{#AppVersion}_windows_x64_setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
WizardStyle=modern
UninstallDisplayIcon={app}\quick_transfer.exe
CloseApplications=yes

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Quick Transfer"; Filename: "{app}\quick_transfer.exe"
Name: "{autodesktop}\Quick Transfer"; Filename: "{app}\quick_transfer.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\quick_transfer.exe"; Description: "Launch Quick Transfer"; Flags: nowait postinstall skipifsilent
