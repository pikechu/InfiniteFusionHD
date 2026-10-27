@echo off

.\REQUIRED_BY_INSTALLER_UPDATER\7z.exe e -spf -aoa "REQUIRED_BY_INSTALLER_UPDATER\MinGit.7z"

set mgit=".\REQUIRED_BY_INSTALLER_UPDATER\cmd\git.exe"
%mgit% init .
%mgit% remote set-url origin "https://github.com/pikechu/InfiniteFusionHD.git" 2>nul
if errorlevel 1 %mgit% remote add origin "https://github.com/pikechu/InfiniteFusionHD.git"
%mgit% fetch origin main
if errorlevel 1 exit /b 1
%mgit% reset --hard origin/main

@REM .\REQUIRED_BY_INSTALLER_UPDATER\7z.exe e -spf -aoa -o"Data" "Data\species.zip"

echo:
echo Installer/Updater made by Hungry Pickle
echo:
echo InfiniteFusionHD installed or updated. You can close this window now.

set arg1=%1
if "%arg1%" == "auto" (
    start "" .\Game.exe
) else (
    pause
)
