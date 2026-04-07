@echo off
setlocal enabledelayedexpansion

echo ============================================
echo   MinIO Sync - Release Pipeline
echo ============================================
echo.

set PROJECT_DIR=%~dp0..
set RELEASE_DIR=%PROJECT_DIR%\release
set TYPE=patch
set DRAFT=
set REPO=ThanhNhanDang/minio_odoo_project

:: ---- Parse arguments ----
:parse_args
if "%~1"=="" goto done_args
if /i "%~1"=="patch" set TYPE=patch
if /i "%~1"=="minor" set TYPE=minor
if /i "%~1"=="major" set TYPE=major
if /i "%~1"=="--draft" set DRAFT=--draft
shift
goto parse_args
:done_args

:: ---- Check prerequisites ----
echo [*] Checking prerequisites...

gh --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] GitHub CLI (gh) not found
    echo         Install: https://cli.github.com/
    exit /b 1
)

D:\flutter\bin\flutter.bat --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Flutter not found at D:\flutter
    exit /b 1
)

node --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Node.js not found (needed for version bump)
    exit /b 1
)

:: ---- Get current version from GitHub ----
echo [*] Fetching current version from GitHub...

for /f "tokens=*" %%i in ('gh release list --repo %REPO% --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq ".[0].tagName" 2^>nul') do set CURRENT_TAG=%%i

if "%CURRENT_TAG%"=="" (
    echo [*] No existing release found, starting from v1.0.0
    set CURRENT_VER=1.0.0
) else (
    set CURRENT_VER=!CURRENT_TAG:v=!
)

echo [*] Current version: %CURRENT_VER%

:: ---- Bump version ----
for /f "tokens=*" %%i in ('node -e "const v='%CURRENT_VER%'.split('.').map(Number); if('%TYPE%'==='major'){v[0]++;v[1]=0;v[2]=0}else if('%TYPE%'==='minor'){v[1]++;v[2]=0}else{v[2]++}; console.log(v.join('.'))"') do set NEW_VER=%%i

echo [*] New version: %NEW_VER% (%TYPE% bump)
echo.

:: ---- Confirm ----
set /p CONFIRM="Continue with release v%NEW_VER%? [y/N] "
if /i not "%CONFIRM%"=="y" (
    echo Aborted.
    exit /b 0
)

:: ---- Clean & prepare ----
if exist "%RELEASE_DIR%" rmdir /s /q "%RELEASE_DIR%"
mkdir "%RELEASE_DIR%"

:: ---- Build Windows ----
echo.
echo [1/4] Building Windows release...
cd /d "%PROJECT_DIR%"

call D:\flutter\bin\flutter.bat pub get >nul 2>&1
call D:\flutter\bin\flutter.bat build windows --release
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Windows build failed
    exit /b 1
)

set BUILD_OUT=%PROJECT_DIR%\build\windows\x64\runner\Release

:: Copy build output
xcopy /s /e /y "%BUILD_OUT%\*" "%RELEASE_DIR%\windows\" >nul

:: Rename main exe for GitHub release
copy "%BUILD_OUT%\minio_sync.exe" "%RELEASE_DIR%\minio-sync-windows-amd64.exe" >nul

echo [OK] Windows build complete

:: ---- Create config template ----
echo [2/4] Creating config template...
(
echo {
echo   "minio_endpoint": "",
echo   "minio_access_key": "",
echo   "minio_secret_key": "",
echo   "minio_bucket": "odoo-documents",
echo   "odoo_url": "",
echo   "odoo_db": "",
echo   "listen_addr": ":9999",
echo   "update_url": "%REPO%",
echo   "version": "%NEW_VER%"
echo }
) > "%RELEASE_DIR%\config.json"

:: ---- Generate checksums ----
echo [3/4] Generating checksums...
cd /d "%RELEASE_DIR%"

(
for %%F in (minio-sync-windows-amd64.exe) do (
    if exist "%%F" (
        for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "%%F" SHA256 2^>nul ^| findstr /v ":" ^| findstr /v "CertUtil"') do (
            echo %%H  %%F
        )
    )
)
) > checksums.txt

echo [OK] Checksums generated

:: ---- Create GitHub Release ----
echo [4/4] Creating GitHub release v%NEW_VER%...

set NOTES=MinIO Sync Flutter v%NEW_VER%
set NOTES=!NOTES!^

^

Assets:^

- minio-sync-windows-amd64.exe (Windows x64)^

- config.json (configuration template)^

- checksums.txt (SHA-256 verification)

set ASSETS=
if exist "%RELEASE_DIR%\minio-sync-windows-amd64.exe" set ASSETS=!ASSETS! "%RELEASE_DIR%\minio-sync-windows-amd64.exe"
if exist "%RELEASE_DIR%\config.json" set ASSETS=!ASSETS! "%RELEASE_DIR%\config.json"
if exist "%RELEASE_DIR%\checksums.txt" set ASSETS=!ASSETS! "%RELEASE_DIR%\checksums.txt"

gh release create "v%NEW_VER%" %ASSETS% --repo %REPO% --title "v%NEW_VER%" --notes "!NOTES!" %DRAFT%
if %ERRORLEVEL% neq 0 (
    echo [ERROR] GitHub release creation failed
    exit /b 1
)

echo.
echo ============================================
echo   RELEASE COMPLETE: v%NEW_VER%
echo ============================================
echo   https://github.com/%REPO%/releases/tag/v%NEW_VER%
echo ============================================

endlocal
