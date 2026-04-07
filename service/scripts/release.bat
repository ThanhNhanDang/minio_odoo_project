@echo off
REM ============================================================
REM  MinIO Service - Release New Version
REM ============================================================
REM
REM  PREREQUISITES:
REM    1. Go 1.21+          go version
REM    2. Node.js           node --version  (for version bump calc)
REM    3. GitHub CLI         gh --version
REM    4. GitHub auth        gh auth login   (one-time setup)
REM
REM  USAGE:
REM    release.bat [patch|minor|major] [--platform] [--draft]
REM
REM  VERSION BUMP:
REM    patch   1.0.0 -> 1.0.1   Bug fixes, minor changes
REM    minor   1.0.0 -> 1.1.0   New features, non-breaking
REM    major   1.0.0 -> 2.0.0   Breaking changes
REM
REM  PLATFORM FLAGS (combine multiple):
REM    --windows    Windows amd64        (with system tray)
REM    --linux      Linux amd64 + arm64  (headless, HTTP only)
REM    --android    Android arm64        (headless, HTTP only)
REM    --all        All platforms         (default if none specified)
REM
REM  OPTIONS:
REM    --draft      Create as draft release (not published)
REM
REM  EXAMPLES:
REM    release.bat patch --windows              Bug fix, Windows only
REM    release.bat minor --linux                New feature, Linux only
REM    release.bat patch --windows --linux      Bug fix, Win + Linux
REM    release.bat major --all                  Breaking change, all
REM    release.bat patch --windows --draft      Draft, review before publish
REM    release.bat patch                        Default = --all
REM
REM  PER-PLATFORM UPDATE BEHAVIOR:
REM    The updater checks GitHub Releases for a binary matching the
REM    running OS/arch. If you only release --windows, then:
REM      - Windows services -> see update, can auto-update
REM      - Linux services   -> NO update (no matching binary)
REM      - Android services -> NO update (no matching binary)
REM    This lets you release platform-specific fixes safely.
REM
REM  WHAT THIS SCRIPT DOES:
REM    1. Reads latest version from GitHub Releases
REM    2. Bumps version (patch/minor/major)
REM    3. Cross-compiles Go binaries for selected platforms
REM    4. Generates SHA-256 checksums (checksums.txt)
REM    5. Creates GitHub Release with all assets uploaded
REM
REM  OUTPUT FILES (in service/release/):
REM    minio-service-windows-amd64.exe   Windows binary
REM    minio-service-linux-amd64         Linux x86_64 binary
REM    minio-service-linux-arm64         Linux ARM64 binary
REM    minio-service-android-arm64       Android ARM64 binary
REM    checksums.txt                     SHA-256 hashes
REM    config.json                       Config template
REM
REM  AFTER RELEASE:
REM    - Running services will detect the update via Check for Update
REM    - Windows: system tray menu or web UI shows update banner
REM    - Linux/Android: web UI shows update banner (no tray)
REM    - Users can apply update via POST /api/system/update
REM
REM  TO PUBLISH A DRAFT:
REM    gh release edit v1.0.1 --draft=false
REM
REM ============================================================
setlocal enabledelayedexpansion

pushd "%~dp0\.."

REM --- Parse arguments ---
set TYPE=patch
set DRAFT=
set BUILD_WINDOWS=0
set BUILD_LINUX=0
set BUILD_ANDROID=0
set PLATFORM_SET=0

for %%a in (%*) do (
    if /i "%%a"=="patch"     set TYPE=patch
    if /i "%%a"=="minor"     set TYPE=minor
    if /i "%%a"=="major"     set TYPE=major
    if /i "%%a"=="--draft"   set DRAFT=--draft
    if /i "%%a"=="--windows" ( set BUILD_WINDOWS=1& set PLATFORM_SET=1 )
    if /i "%%a"=="--linux"   ( set BUILD_LINUX=1& set PLATFORM_SET=1 )
    if /i "%%a"=="--android" ( set BUILD_ANDROID=1& set PLATFORM_SET=1 )
    if /i "%%a"=="--all"     ( set BUILD_WINDOWS=1& set BUILD_LINUX=1& set BUILD_ANDROID=1& set PLATFORM_SET=1 )
)

REM Default: build all if no platform specified
if %PLATFORM_SET%==0 (
    set BUILD_WINDOWS=1
    set BUILD_LINUX=1
    set BUILD_ANDROID=1
)

REM --- Check gh CLI ---
where gh >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] GitHub CLI ^(gh^) not found!
    echo   Install: https://cli.github.com/
    popd
    exit /b 1
)

REM --- Read current version from GitHub ---
set CURRENT_VER=
for /f %%v in ('gh release list --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq ".[0].tagName" 2^>nul') do set CURRENT_TAG=%%v
if "%CURRENT_TAG%"=="" (
    echo   No previous release found. Starting from 1.0.0
    set CURRENT_VER=1.0.0
) else (
    set CURRENT_VER=!CURRENT_TAG:~1!
    echo   Current release: !CURRENT_TAG! ^(!CURRENT_VER!^)
)

REM --- Bump version ---
for /f %%v in ('node -e "const p=('%CURRENT_VER%').split('.').map(Number);if('%TYPE%'==='major'){p[0]++;p[1]=0;p[2]=0}else if('%TYPE%'==='minor'){p[1]++;p[2]=0}else{p[2]++};console.log(p.join('.'))"') do set NEW_VER=%%v
echo   Bump type:       %TYPE%
echo   New version:     %NEW_VER%

REM --- Show selected platforms ---
set PLATFORMS=
if %BUILD_WINDOWS%==1 set PLATFORMS=!PLATFORMS! windows
if %BUILD_LINUX%==1   set PLATFORMS=!PLATFORMS! linux
if %BUILD_ANDROID%==1 set PLATFORMS=!PLATFORMS! android
echo   Platforms:      !PLATFORMS!

set APP_NAME=minio-service
set RELEASE_DIR=release

echo.
echo ============================================================
echo   Building release v%NEW_VER% [!PLATFORMS! ]
echo ============================================================

REM --- Clean previous release ---
echo.
echo   Stopping running services to avoid file lock...
taskkill /f /im minio-service-windows-amd64.exe >nul 2>&1
taskkill /f /im minio-service.exe >nul 2>&1

if exist %RELEASE_DIR% rmdir /s /q %RELEASE_DIR%
mkdir %RELEASE_DIR%

REM --- Build selected platforms ---

if %BUILD_WINDOWS%==1 (
    echo.
    echo --- Windows ^(amd64^) ---
    set GOOS=windows
    set GOARCH=amd64
    REM Workaround: Go 1.26 IOCP network poller init breaks fyne.io/systray
    REM window creation on Windows (Shell_NotifyIcon "Unspecified error").
    REM Pin to Go 1.25.x until a fix lands in Go 1.26.x+.
    set GOTOOLCHAIN=go1.25.4
    REM Generate Windows resource (icon + version info) before building
    pushd cmd\minio-service
    goversioninfo -64 -o resource.syso versioninfo.json
    popd
    go build -ldflags="-s -w -X main.version=%NEW_VER%" -o %RELEASE_DIR%\%APP_NAME%-windows-amd64.exe .\cmd\minio-service\
    if !ERRORLEVEL! NEQ 0 (
        echo BUILD FAILED for windows/amd64
        popd
        exit /b 1
    )
    for %%A in (%RELEASE_DIR%\%APP_NAME%-windows-amd64.exe) do echo    OK: %APP_NAME%-windows-amd64.exe ^(%%~zA bytes^)

    REM Prepare installer inputs
    copy /Y %RELEASE_DIR%\%APP_NAME%-windows-amd64.exe %RELEASE_DIR%\%APP_NAME%.exe >nul
    echo {"minio_endpoint":"","minio_access_key":"","minio_secret_key":"","minio_bucket":"odoo-documents","odoo_url":"","odoo_db":"","listen_addr":":9999","update_url":"ThanhNhanDang/minio_odoo_project"} > %RELEASE_DIR%\config.json

    REM --- Build Windows Installer ---
    set ISCC=
    where iscc >nul 2>&1
    if !ERRORLEVEL!==0 (
        set ISCC=iscc
    ) else if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
        set ISCC="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    ) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
        set ISCC="C:\Program Files\Inno Setup 6\ISCC.exe"
    )
    if defined ISCC (
        echo.
        echo --- Windows Installer ---
        !ISCC! /DMyAppVersion=%NEW_VER% scripts\installer.iss >nul
        if !ERRORLEVEL!==0 (
            for %%A in (%RELEASE_DIR%\MinIO-Service-Setup-v%NEW_VER%.exe) do echo    OK: MinIO-Service-Setup-v%NEW_VER%.exe ^(%%~zA bytes^)
        ) else (
            echo    WARN: Installer build failed, skipping
        )
    ) else (
        echo    SKIP: Inno Setup not found, no installer built
    )
    del /Q %RELEASE_DIR%\%APP_NAME%.exe >nul 2>&1
)

if %BUILD_LINUX%==1 (
    echo.
    echo --- Linux ^(amd64^) ---
    set GOOS=linux
    set GOARCH=amd64
    go build -ldflags="-s -w -X main.version=%NEW_VER%" -o %RELEASE_DIR%\%APP_NAME%-linux-amd64 .\cmd\minio-service\
    if !ERRORLEVEL! NEQ 0 (
        echo BUILD FAILED for linux/amd64
        popd
        exit /b 1
    )
    for %%A in (%RELEASE_DIR%\%APP_NAME%-linux-amd64) do echo    OK: %APP_NAME%-linux-amd64 ^(%%~zA bytes^)

    echo.
    echo --- Linux ^(arm64^) ---
    set GOOS=linux
    set GOARCH=arm64
    go build -ldflags="-s -w -X main.version=%NEW_VER%" -o %RELEASE_DIR%\%APP_NAME%-linux-arm64 .\cmd\minio-service\
    if !ERRORLEVEL! NEQ 0 (
        echo BUILD FAILED for linux/arm64
        popd
        exit /b 1
    )
    for %%A in (%RELEASE_DIR%\%APP_NAME%-linux-arm64) do echo    OK: %APP_NAME%-linux-arm64 ^(%%~zA bytes^)
)

if %BUILD_ANDROID%==1 (
    echo.
    echo --- Android ^(arm64^) ---
    set GOOS=android
    set GOARCH=arm64
    go build -ldflags="-s -w -X main.version=%NEW_VER%" -o %RELEASE_DIR%\%APP_NAME%-android-arm64 .\cmd\minio-service\
    if !ERRORLEVEL! NEQ 0 (
        echo BUILD FAILED for android/arm64
        popd
        exit /b 1
    )
    for %%A in (%RELEASE_DIR%\%APP_NAME%-android-arm64) do echo    OK: %APP_NAME%-android-arm64 ^(%%~zA bytes^)
)

REM --- Generate checksums.txt ---
echo.
echo --- Generating checksums ---
cd %RELEASE_DIR%
(echo.) > checksums.txt

if %BUILD_WINDOWS%==1 (
    certutil -hashfile %APP_NAME%-windows-amd64.exe SHA256 | findstr /v ":" > tmp_hash.txt
    set /p HASH=<tmp_hash.txt
    echo !HASH!  %APP_NAME%-windows-amd64.exe>> checksums.txt
    del tmp_hash.txt
)
if %BUILD_LINUX%==1 (
    certutil -hashfile %APP_NAME%-linux-amd64 SHA256 | findstr /v ":" > tmp_hash.txt
    set /p HASH=<tmp_hash.txt
    echo !HASH!  %APP_NAME%-linux-amd64>> checksums.txt
    del tmp_hash.txt

    certutil -hashfile %APP_NAME%-linux-arm64 SHA256 | findstr /v ":" > tmp_hash.txt
    set /p HASH=<tmp_hash.txt
    echo !HASH!  %APP_NAME%-linux-arm64>> checksums.txt
    del tmp_hash.txt
)
if %BUILD_ANDROID%==1 (
    certutil -hashfile %APP_NAME%-android-arm64 SHA256 | findstr /v ":" > tmp_hash.txt
    set /p HASH=<tmp_hash.txt
    echo !HASH!  %APP_NAME%-android-arm64>> checksums.txt
    del tmp_hash.txt
)
echo    OK: checksums.txt
cd ..

REM --- Ensure config template exists (may already be created by installer step) ---
if not exist %RELEASE_DIR%\config.json (
    echo {"minio_endpoint":"","minio_access_key":"","minio_secret_key":"","minio_bucket":"odoo-documents","odoo_url":"","odoo_db":"","listen_addr":":9999","update_url":"ThanhNhanDang/minio_odoo_project"} > %RELEASE_DIR%\config.json
)

echo.
echo ============================================================
echo   Uploading to GitHub Releases...
echo ============================================================
echo.

REM --- Build asset list dynamically ---
set ASSETS=%RELEASE_DIR%\checksums.txt %RELEASE_DIR%\config.json
if %BUILD_WINDOWS%==1 (
    set ASSETS=%RELEASE_DIR%\%APP_NAME%-windows-amd64.exe !ASSETS!
    if exist %RELEASE_DIR%\MinIO-Service-Setup-v%NEW_VER%.exe set ASSETS=%RELEASE_DIR%\MinIO-Service-Setup-v%NEW_VER%.exe !ASSETS!
)
if %BUILD_LINUX%==1   set ASSETS=%RELEASE_DIR%\%APP_NAME%-linux-amd64 %RELEASE_DIR%\%APP_NAME%-linux-arm64 !ASSETS!
if %BUILD_ANDROID%==1 set ASSETS=%RELEASE_DIR%\%APP_NAME%-android-arm64 !ASSETS!

REM --- Build release notes ---
set NOTES=## MinIO Service v%NEW_VER%\n\n### Assets\n
if %BUILD_WINDOWS%==1 set NOTES=!NOTES!- **Windows Installer**: MinIO-Service-Setup-v%NEW_VER%.exe\n- **Windows** ^(amd64^): minio-service-windows-amd64.exe\n
if %BUILD_LINUX%==1   set NOTES=!NOTES!- **Linux** ^(amd64^): minio-service-linux-amd64\n- **Linux** ^(arm64^): minio-service-linux-arm64\n
if %BUILD_ANDROID%==1 set NOTES=!NOTES!- **Android** ^(arm64^): minio-service-android-arm64\n
set NOTES=!NOTES!\nSee checksums.txt for SHA-256 verification.

REM --- Create GitHub Release ---
gh release create v%NEW_VER% !ASSETS! --title "v%NEW_VER%" --notes "!NOTES!" %DRAFT%

if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] GitHub release creation failed!
    popd
    exit /b 1
)

echo.
echo ============================================================
echo   Released v%NEW_VER% successfully! [!PLATFORMS! ]
echo   https://github.com/ThanhNhanDang/minio_odoo_project/releases
echo ============================================================
echo.

popd
