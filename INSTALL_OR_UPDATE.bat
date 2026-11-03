@echo off
setlocal
cd /d "%~dp0"

.\REQUIRED_BY_INSTALLER_UPDATER\7z.exe e -spf -aoa "REQUIRED_BY_INSTALLER_UPDATER\MinGit.7z"

set mgit=".\REQUIRED_BY_INSTALLER_UPDATER\cmd\git.exe"
%mgit% init .
if errorlevel 1 exit /b 1
%mgit% remote set-url origin "https://github.com/pikechu/InfiniteFusionHD.git" 2>nul
if errorlevel 1 %mgit% remote add origin "https://github.com/pikechu/InfiniteFusionHD.git"
if errorlevel 1 exit /b 1
%mgit% fetch origin main
if errorlevel 1 goto failed
%mgit% rev-parse --verify HEAD >nul 2>nul
if errorlevel 1 (
    %mgit% reset --hard origin/main
) else (
    %mgit% diff --quiet
    if errorlevel 1 goto modified
    %mgit% diff --cached --quiet
    if errorlevel 1 goto modified
    %mgit% merge --ff-only origin/main
)
if errorlevel 1 goto failed

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
exit /b 0

:modified
echo Local changes were found. Update cancelled to preserve your files.
pause
exit /b 1

:failed
echo Update failed. Your current game was kept. Check the connection or install the latest version from:
echo https://github.com/pikechu/InfiniteFusionHD
pause
exit /b 1
