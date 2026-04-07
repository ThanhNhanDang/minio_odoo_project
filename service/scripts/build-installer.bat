@echo off
REM ============================================================
REM  MinIO Service - Build Windows Installer
REM
REM  PREREQUISITES:
REM    1. Go 1.21+              go version
REM    2. Inno Setup 6+         https://jrsoftware.org/isinfo.php
REM       (add to PATH or install to default location)
REM
REM  USAGE:
REM    build-installer.bat [version]
REM
REM  EXAMPLES:
REM    build-installer.bat              Uses version from latest GitHub release + patch
REM    build-installer.bat 1.0.7        Explicit version
REM
REM  OUTPUT:
REM    release\MinIO-Service-Setup-vX.Y.Z.exe
REM
REM ============================================================
setlocal enabledelayedexpansion

pushd "%~dp0\.."

set APP_NAME=minio-service
set RELEASE_DIR=release

REM --- Determine version ---
set VER=%1
if "%VER%"=="" (
    REM Try to get from latest GitHub release
    for /f %%v in ('gh release list --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq ".[0].tagName" 2^>nul') do set CURRENT_TAG=%%v
    if "!CURRENT_TAG!"=="" (
        set VER=1.0.0
    ) else (
        set VER=!CURRENT_TAG:~1!
    )
)
echo   Version: %VER%

REM --- Clean ---
if exist %RELEASE_DIR% rmdir /s /q %RELEASE_DIR%
mkdir %RELEASE_DIR%

REM --- Build Windows exe ---
echo.
echo === Building %APP_NAME%.exe v%VER% ===
set GOOS=windows
set GOARCH=amd64
go build -ldflags="-s -w -H windowsgui -X main.version=%VER%" -o %RELEASE_DIR%\%APP_NAME%.exe .\cmd\minio-service\
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Build failed!
    popd
    exit /b 1
)
for %%A in (%RELEASE_DIR%\%APP_NAME%.exe) do echo    OK: %APP_NAME%.exe ^(%%~zA bytes^)

REM --- Create config template ---
echo {"minio_endpoint":"","minio_access_key":"","minio_secret_key":"","minio_bucket":"odoo-documents","odoo_url":"","odoo_db":"","listen_addr":":9999","update_url":"ThanhNhanDang/minio_odoo_project"} > %RELEASE_DIR%\config.json

REM --- Find Inno Setup compiler ---
set ISCC=
where iscc >nul 2>&1
if %ERRORLEVEL%==0 (
    set ISCC=iscc
) else if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set ISCC="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
    set ISCC="C:\Program Files\Inno Setup 6\ISCC.exe"
) else (
    echo.
    echo [ERROR] Inno Setup not found!
    echo   Install from: https://jrsoftware.org/isinfo.php
    echo   Then add to PATH or install to default location.
    echo.
    echo   The exe was built successfully in %RELEASE_DIR%\
    echo   but the installer could not be created.
    popd
    exit /b 1
)

REM --- Build installer ---
echo.
echo === Building installer ===
%ISCC% /DMyAppVersion=%VER% scripts\installer.iss
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Installer build failed!
    popd
    exit /b 1
)

echo.
echo ============================================================
echo   Installer built successfully!
echo   Output: %RELEASE_DIR%\MinIO-Service-Setup-v%VER%.exe
echo ============================================================
echo.

popd
