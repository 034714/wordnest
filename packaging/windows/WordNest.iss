; Compile through package.py after release_helpers.py records validated builds.
; All release identity and paths come from pubspec.yaml and CLI parameters.
#ifndef ProjectRoot
  #error ProjectRoot must be supplied by package.py
#endif
#ifndef Version
  #error Version must be supplied from pubspec.yaml by package.py
#endif
#ifndef WindowsVersion
  #error WindowsVersion must be supplied from pubspec.yaml by package.py
#endif
#ifndef OutputRoot
  #error OutputRoot must be supplied by package.py
#endif
#ifndef SupplementalFiles
  #error SupplementalFiles must be supplied by package.py
#endif
#define ReleaseRoot ProjectRoot + "\build\windows\x64\runner\Release"

[Setup]
AppId={{A92F1848-673A-44CC-944B-5FBB38E4376E}
AppName=WordNest
AppVersion={#Version}
AppVerName=WordNest {#Version}
AppPublisher=WordNest
VersionInfoVersion={#WindowsVersion}
DefaultDirName={localappdata}\Programs\WordNest
DefaultGroupName=WordNest
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0
OutputDir={#OutputRoot}
OutputBaseFilename=WordNest-windows-x64-setup
SetupIconFile={#ProjectRoot}\assets\tray.ico
UninstallDisplayIcon={app}\WordNest.ico
UninstallDisplayName=WordNest
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
WizardSizePercent=110
WizardImageFile={#SourcePath}\artwork\wizard.bmp
WizardSmallImageFile={#SourcePath}\artwork\wizard-small.bmp
WizardImageStretch=yes
WizardImageBackColor=$F5F8F2
WizardBackColor=#f5f8f2
DisableWelcomePage=no
ShowLanguageDialog=yes
LanguageDetectionMethod=none
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "{#SourcePath}\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
chinesesimplified.WelcomeLabel1=欢迎使用词栖 WordNest
chinesesimplified.WelcomeLabel2=给单词一个安静生长的地方。%n%n即将为当前 Windows 用户安装词栖 WordNest {#Version}，无需管理员权限。%n%n更新或卸载应用时，会保留您的本地词书、笔记和学习记录。
chinesesimplified.FinishedHeadingLabel=词栖已准备好
chinesesimplified.FinishedLabel=词栖 WordNest 已安装完成。%n%n您可以载入演示词书，也可以导入自己的词书。请在“我的词书”中导出完整 JSON 备份，妥善保存学习记录。
english.WelcomeLabel1=Welcome to WordNest
english.WelcomeLabel2=A quiet place for words to grow.%n%nInstall WordNest {#Version} for your Windows account. No administrator access is required.%n%nYour local wordbooks, notes and learning history are kept when updating or uninstalling.
english.FinishedHeadingLabel=Your word nest is ready
english.FinishedLabel=WordNest is installed.%n%nStart with the demo wordbook or import your own. Export JSON backups from My Wordbooks to protect your learning history.

[CustomMessages]
chinesesimplified.DesktopShortcut=创建桌面快捷方式(&D)
chinesesimplified.ShortcutsGroup=快捷方式：
chinesesimplified.LaunchWordNest=启动词栖 WordNest(&L)
english.DesktopShortcut=Create a &desktop shortcut
english.ShortcutsGroup=Shortcuts:
english.LaunchWordNest=&Launch WordNest

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopShortcut}"; GroupDescription: "{cm:ShortcutsGroup}"; Flags: unchecked

[Files]
Source: "{#ReleaseRoot}\*"; DestDir: "{app}"; Excludes: "*.lib,*.exp"; Flags: ignoreversion recursesubdirs createallsubdirs
; Generated from the same supplemental source map used by ZIP validation.
#include SupplementalFiles

[Icons]
Name: "{userprograms}\WordNest"; Filename: "{app}\wordnest.exe"; WorkingDir: "{app}"; IconFilename: "{app}\WordNest.ico"
Name: "{userdesktop}\WordNest"; Filename: "{app}\wordnest.exe"; WorkingDir: "{app}"; IconFilename: "{app}\WordNest.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\wordnest.exe"; Description: "{cm:LaunchWordNest}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent unchecked

; No startup entries, data migration, or [UninstallDelete] rules.
; User data lives in the application's support directory, outside {app}.

[Code]
procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel1.Font.Color := $004D6330;
  WizardForm.FinishedHeadingLabel.Font.Color := $004D6330;
  WizardForm.PageNameLabel.Font.Color := $004D6330;
end;
