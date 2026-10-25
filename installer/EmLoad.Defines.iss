; ---------------------------------------------------------------------------
; Defaults for the EmLoad installers.
;
; build-installer.ps1 writes build.defines.iss (absolute paths, version, output
; folder) and it is picked up here first. Everything below only applies when a
; value was not supplied, so the scripts can also be compiled by hand from the
; installer folder after a staged build.
; ---------------------------------------------------------------------------

#ifexist "build.defines.iss"
  #include "build.defines.iss"
#endif

#ifndef StageDir
  #define StageDir "stage"
#endif

#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

#ifndef RepoRoot
  #define RepoRoot ".."
#endif

; The release this installer publishes.
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#ifndef AppPrerelease
  #define AppPrerelease "Beta 1"
#endif

; Used in file names: EmLoad-Setup-0.1.0-beta1.exe
#ifndef OutputTag
  #define OutputTag "0.1.0-beta1"
#endif

#define AppName "EmLoad"
#define AppPublisher "EmLoad contributors"
#define AppUrl "https://github.com/EmTechFlagship/EmLoadServer"
#define AppExeName "EmLoad.WinUI.exe"

; Shown to the user: EmLoad 0.1.0 Beta 1
#define BuildLabel AppVersion + " " + AppPrerelease
