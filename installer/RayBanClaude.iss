; RayBan Claude – Windows installer (Inno Setup 6)
;
; Builds RayBanClaude-Setup.exe: copies the channel and scripts to %LOCALAPPDATA%\Programs\RayBanClaude
; (no administrator rights needed), sets up Bun and Claude Code with the official installers,
; opens the Windows firewall on request (asks for administrator rights once) and places
; “RayBan Claude” on the desktop and in the Start menu.
;
; Built in GitHub Actions (.github/workflows/windows-installer.yml):
;   ISCC.exe /DAppVersion=2.1.0 installer\RayBanClaude.iss

#define AppName "RayBan Claude"
#ifndef AppVersion
  #define AppVersion "2.1.0"
#endif
#define RepoUrl "https://github.com/MoinMornhart/RayBanClaude"

[Setup]
AppId={{6C1F3B52-8E47-4C0A-9B6D-2F7E91A4C3D8}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=RayBan Claude (Open Source)
AppPublisherURL={#RepoUrl}
AppSupportURL={#RepoUrl}/issues
AppUpdatesURL={#RepoUrl}/releases
DefaultDirName={localappdata}\Programs\RayBanClaude
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=RayBanClaude-Setup
SetupIconFile=RayBanClaude.ico
UninstallDisplayIcon={app}\RayBanClaude.ico
UninstallDisplayName={#AppName}
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
; Bun needs Windows 10 version 1809 or newer
MinVersion=10.0.17763
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
english.WelcomeLabel2=This lets Claude see what you see – with your Ray-Ban Meta (Gen 2) or your iPhone.%n%nThe installer sets up everything your PC needs: Bun and Claude Code (official installers, free), the RayBan Claude channel and – if installed – the link to the Claude desktop app. You need a Claude subscription (Pro or Max) to use Claude.%n%nUnofficial open-source project – not affiliated with Meta, Ray-Ban or Anthropic.
english.FinishedLabel=RayBan Claude is set up.%n%nOn first launch you sign in to Claude once (your browser opens) and confirm “Use this MCP server”. The dashboard then opens – scan the QR code there with the iPhone camera.%n%nYou install the iPhone app without a Mac using Sideloadly (instructions in the Start menu).

[Tasks]
Name: "desktopicon"; Description: "Create a “RayBan Claude” icon on the desktop"
Name: "firewall"; Description: "Open the Windows firewall for the iPhone (home Wi-Fi and Tailscale only – asks for administrator rights)"

[Files]
Source: "..\channel\*"; DestDir: "{app}\channel"; Excludes: "\node_modules\*,\test\*,*.log"; Flags: recursesubdirs ignoreversion
Source: "..\.mcp.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\setup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\setup.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\start.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\start.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\firewall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\IPHONE-OHNE-MAC.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "RayBanClaude.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\RayBan Claude\RayBan Claude"; Filename: "{app}\start.cmd"; WorkingDir: "{app}"; IconFilename: "{app}\RayBanClaude.ico"; Comment: "Start Claude with Ray-Ban Meta and iPhone"
Name: "{autoprograms}\RayBan Claude\New conversation"; Filename: "{app}\start.cmd"; Parameters: "-Neu"; WorkingDir: "{app}"; IconFilename: "{app}\RayBanClaude.ico"; Comment: "Start RayBan Claude without the last conversation"
Name: "{autoprograms}\RayBan Claude\Repeat setup"; Filename: "{app}\setup.cmd"; WorkingDir: "{app}"; IconFilename: "{app}\RayBanClaude.ico"
Name: "{autoprograms}\RayBan Claude\Install the iPhone app (guide)"; Filename: "{#RepoUrl}/blob/main/docs/IPHONE-OHNE-MAC.md"
Name: "{autoprograms}\RayBan Claude\Uninstall RayBan Claude"; Filename: "{uninstallexe}"
Name: "{autodesktop}\RayBan Claude"; Filename: "{app}\start.cmd"; WorkingDir: "{app}"; IconFilename: "{app}\RayBanClaude.ico"; Comment: "Start Claude with Ray-Ban Meta and iPhone"; Tasks: desktopicon

[Run]
; Bun, Claude Code (official installers) and the channel dependencies – in a visible window
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup.ps1"" -Unattended"; WorkingDir: "{app}"; StatusMsg: "Setting up Bun, Claude Code and the channel …"; Flags: waituntilterminated
; Firewall: only this step needs administrator rights
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\firewall.ps1"""; Verb: "runas"; StatusMsg: "Opening the Windows firewall for the iPhone …"; Flags: shellexec waituntilterminated; Tasks: firewall
Filename: "{app}\start.cmd"; WorkingDir: "{app}"; Description: "Start RayBan Claude now"; Flags: postinstall shellexec nowait skipifsilent
Filename: "{#RepoUrl}/blob/main/docs/IPHONE-OHNE-MAC.md"; Description: "Open the guide: app on the iPhone (without a Mac)"; Flags: postinstall shellexec nowait skipifsilent unchecked

[UninstallRun]
; Remove the link to the Claude desktop app again
Filename: "{%USERPROFILE}\.bun\bin\bun.exe"; Parameters: """{app}\channel\link-desktop.ts"" --remove"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "ClaudeAppTrennen"
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\firewall.ps1"" -Remove"; Verb: "runas"; Flags: shellexec waituntilterminated; RunOnceId: "FirewallEntfernen"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\channel\node_modules"
