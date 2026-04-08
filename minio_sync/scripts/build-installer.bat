@echo off
echo === Building MinIO Sync Installer ===
echo.

echo [1/2] Building Flutter release...
cd /d "%~dp0.."
call "C:\flutter\bin\flutter.bat" build windows --release
if errorlevel 1 (
    echo FAILED: Flutter build failed
    pause
    exit /b 1
)

echo.
echo [2/2] Creating installer with Inno Setup...
where iscc >nul 2>&1
if errorlevel 1 (
    if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" scripts\installer.iss
    ) else (
        echo ERROR: Inno Setup not found. Install from https://jrsoftware.org/issetup.exe
        pause
        exit /b 1
    )
) else (
    iscc scripts\installer.iss
)

if errorlevel 1 (
    echo FAILED: Installer build failed
    pause
    exit /b 1
)

echo.
echo === Done! Installer at: build\installer\MinIOSync-1.0.0-Setup.exe ===
pause
