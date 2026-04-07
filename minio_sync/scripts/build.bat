@echo off
setlocal enabledelayedexpansion

echo ============================================
echo   MinIO Sync - Flutter Windows Build
echo ============================================
echo.

set VERSION=1.0.0
set PROJECT_DIR=%~dp0..
set OUTPUT_DIR=%PROJECT_DIR%\release

:: Parse arguments
if not "%~1"=="" set VERSION=%~1

echo [*] Version: %VERSION%
echo [*] Project: %PROJECT_DIR%
echo.

:: Clean previous build
if exist "%OUTPUT_DIR%" rmdir /s /q "%OUTPUT_DIR%"
mkdir "%OUTPUT_DIR%"

:: Get dependencies
echo [1/4] Getting dependencies...
cd /d "%PROJECT_DIR%"
call D:\flutter\bin\flutter.bat pub get
if %ERRORLEVEL% neq 0 (
    echo [ERROR] flutter pub get failed
    exit /b 1
)

:: Analyze code
echo [2/4] Analyzing code...
call D:\flutter\bin\flutter.bat analyze --no-fatal-infos
if %ERRORLEVEL% neq 0 (
    echo [WARNING] Analysis found issues, continuing...
)

:: Build Windows release
echo [3/4] Building Windows release...
call D:\flutter\bin\flutter.bat build windows --release
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Build failed
    exit /b 1
)

:: Copy artifacts to release/
echo [4/4] Packaging release...
set BUILD_OUT=%PROJECT_DIR%\build\windows\x64\runner\Release
if not exist "%BUILD_OUT%\minio_sync.exe" (
    echo [ERROR] Build output not found at %BUILD_OUT%
    exit /b 1
)

:: Copy entire Release folder (includes DLLs and data)
xcopy /s /e /y "%BUILD_OUT%\*" "%OUTPUT_DIR%\" >nul

:: Copy config template
echo { > "%OUTPUT_DIR%\config.json"
echo   "minio_endpoint": "", >> "%OUTPUT_DIR%\config.json"
echo   "minio_access_key": "", >> "%OUTPUT_DIR%\config.json"
echo   "minio_secret_key": "", >> "%OUTPUT_DIR%\config.json"
echo   "minio_bucket": "odoo-documents", >> "%OUTPUT_DIR%\config.json"
echo   "odoo_url": "", >> "%OUTPUT_DIR%\config.json"
echo   "odoo_db": "", >> "%OUTPUT_DIR%\config.json"
echo   "listen_addr": ":9999", >> "%OUTPUT_DIR%\config.json"
echo   "update_url": "ThanhNhanDang/minio_odoo_project", >> "%OUTPUT_DIR%\config.json"
echo   "version": "%VERSION%" >> "%OUTPUT_DIR%\config.json"
echo } >> "%OUTPUT_DIR%\config.json"

:: Rename exe for consistency
copy "%OUTPUT_DIR%\minio_sync.exe" "%OUTPUT_DIR%\minio-sync-windows-amd64.exe" >nul

:: Show result
echo.
echo ============================================
echo   BUILD COMPLETE
echo ============================================
for %%A in ("%OUTPUT_DIR%\minio_sync.exe") do echo   Size: %%~zA bytes
echo   Output: %OUTPUT_DIR%
echo ============================================

endlocal
