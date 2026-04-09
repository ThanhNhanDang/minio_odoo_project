@echo on
REM ============================================================
REM  MinIO Sync - Publish New Version (Windows + Linux + Android)
REM  Usage: publish.bat [patch|minor|major]
REM
REM  patch: 1.0.0 -> 1.0.1 (bug fixes)
REM  minor: 1.0.0 -> 1.1.0 (new features)
REM  major: 1.0.0 -> 2.0.0 (breaking changes)
REM
REM  Requires: gh CLI authenticated (gh auth login)
REM  Requires: Inno Setup 6 installed (for Windows installer)
REM ============================================================

set TYPE=%1
if "%TYPE%"=="" set TYPE=patch

if not "%TYPE%"=="patch" if not "%TYPE%"=="minor" if not "%TYPE%"=="major" (
    echo [ERROR] Invalid version type: %TYPE%
    echo Usage: publish.bat [patch^|minor^|major]
    pause
    exit /b 1
)

cd /d "%~dp0.."

echo.
echo ============================================================
echo   Publishing %TYPE% release (Windows + Linux + Android)
echo ============================================================
echo.

REM --- Setup Flutter Path ---
where flutter >nul 2>&1
if errorlevel 1 (
    echo [WARNING] Flutter not found in PATH.
    if exist "D:\flutter\bin\flutter.bat" (
        echo Adding D:\flutter\bin to PATH...
        set "PATH=D:\flutter\bin;%PATH%"
    ) else if exist "C:\flutter\bin\flutter.bat" (
        echo Adding C:\flutter\bin to PATH...
        set "PATH=C:\flutter\bin;%PATH%"
    ) else if exist "C:\src\flutter\bin\flutter.bat" (
        echo Adding C:\src\flutter\bin to PATH...
        set "PATH=C:\src\flutter\bin;%PATH%"
    ) else (
        echo [ERROR] Flutter not found. Please add FLUTTER to PATH.
        pause
        exit /b 1
    )
)

REM --- Get current version from pubspec.yaml ---
for /f "tokens=2 delims= " %%a in ('findstr /R "^version:" pubspec.yaml') do set FULL_VER=%%a
for /f "tokens=1 delims=+" %%a in ("%FULL_VER%") do set CUR_VER=%%a
echo   Current version: %CUR_VER%

REM --- Bump version ---
for /f "tokens=1-3 delims=." %%a in ("%CUR_VER%") do (
    set MAJOR=%%a
    set MINOR=%%b
    set PATCH=%%c
)

if "%TYPE%"=="patch" set /a PATCH+=1
if "%TYPE%"=="minor" (
    set /a MINOR+=1
    set PATCH=0
)
if "%TYPE%"=="major" (
    set /a MAJOR+=1
    set MINOR=0
    set PATCH=0
)

set NEW_VER=%MAJOR%.%MINOR%.%PATCH%
echo   New version:     %NEW_VER%
echo.

REM --- Update version in files ---
echo   Updating pubspec.yaml, installer.iss, and version.dart...
powershell -Command "(Get-Content pubspec.yaml) -replace 'version: .*', 'version: %NEW_VER%+1' | Set-Content pubspec.yaml"
powershell -Command "(Get-Content scripts\installer.iss) -replace '#define MyAppVersion .*', '#define MyAppVersion \"%NEW_VER%\"' | Set-Content scripts\installer.iss"
powershell -Command "(Get-Content lib\version.dart) -replace 'const String appVersion = .*', 'const String appVersion = ''%NEW_VER%'';' | Set-Content lib\version.dart"

REM --- Create output directory ---
if not exist "build\installer" mkdir "build\installer"

REM ============================================================
REM  WINDOWS BUILD
REM ============================================================
echo.
echo ============================================================
echo   [1/5] Building Flutter Windows release...
echo ============================================================
call flutter build windows --release
if errorlevel 1 (
    echo [ERROR] Windows build failed!
    pause
    exit /b 1
)
echo   [OK] Windows build complete.

echo.
echo ============================================================
echo   [2/5] Building Windows installer...
echo ============================================================
set WIN_INSTALLER=build\installer\MinIOSync-%NEW_VER%-Setup.exe
set ISCC=
if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
) else if exist "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" (
    set "ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"
)
if defined ISCC (
    "%ISCC%" scripts\installer.iss
    echo   [OK] Installer: %WIN_INSTALLER%
) else (
    echo   [ERROR] Inno Setup not found! Install it: winget install JRSoftware.InnoSetup
    set WIN_INSTALLER=
)

REM ============================================================
REM  CODE SIGNING (auto-creates certificate if not found)
REM ============================================================
set CERT_FILE=%~dp0certs\minio-sync-signing.pfx
set CERT_PASS=MinIOSync2024
set SIGNTOOL=C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe

if defined WIN_INSTALLER if exist "%WIN_INSTALLER%" (
    if not exist "%CERT_FILE%" (
        echo.
        echo   No certificate found. Creating one automatically...
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0create-cert.ps1" -Password "%CERT_PASS%"
    )
    if exist "%CERT_FILE%" (
        echo.
        echo   Signing installer with code signing certificate...
        "%SIGNTOOL%" sign /f "%CERT_FILE%" /p "%CERT_PASS%" /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /d "MinIO Sync" "%WIN_INSTALLER%"
        if errorlevel 1 (
            echo   [WARNING] Code signing failed! Continuing without signature.
        ) else (
            echo   [OK] Installer signed successfully.
        )
    )
)

REM ============================================================
REM  LINUX BUILD (skip on Windows — need Linux host)
REM ============================================================
echo.
echo   [3/5] Linux build: SKIPPED (requires Linux host)
set LINUX_TAR=

REM ============================================================
REM  ANDROID BUILD
REM ============================================================
echo.
echo ============================================================
echo   [4/5] Building Android APK...
echo ============================================================
set ANDROID_APK=build\installer\MinIOSync-%NEW_VER%.apk
call flutter build apk --release 2>nul
if not exist "build\app\outputs\flutter-apk\app-release.apk" (
    echo   [WARNING] Android build failed or not configured. Skipping.
    set ANDROID_APK=
) else (
    copy /Y "build\app\outputs\flutter-apk\app-release.apk" "%ANDROID_APK%" >nul
    echo   [OK] Android APK: %ANDROID_APK%
)

REM ============================================================
REM  PUBLISH TO GITHUB
REM ============================================================

REM Save absolute path to minio_sync dir before cd'ing away
set SYNC_DIR=%CD%

echo.
echo ============================================================
echo   [5/5] Creating GitHub release v%NEW_VER%...
echo ============================================================

REM Generate checksums for all assets (format: "<sha256>  <filename>" per line)
echo. > "%SYNC_DIR%\build\installer\checksums.txt"
if defined WIN_INSTALLER if exist "%SYNC_DIR%\%WIN_INSTALLER%" (
    echo   Checksum: %WIN_INSTALLER%
    for /f "tokens=*" %%h in ('certutil -hashfile "%SYNC_DIR%\%WIN_INSTALLER%" SHA256 ^| findstr /v "hash" ^| findstr /v "CertUtil"') do (
        echo %%h  MinIOSync-%NEW_VER%-Setup.exe>> "%SYNC_DIR%\build\installer\checksums.txt"
    )
)
if defined LINUX_TAR if exist "%SYNC_DIR%\%LINUX_TAR%" (
    echo   Checksum: %LINUX_TAR%
    for /f "tokens=*" %%h in ('certutil -hashfile "%SYNC_DIR%\%LINUX_TAR%" SHA256 ^| findstr /v "hash" ^| findstr /v "CertUtil"') do (
        echo %%h  MinIOSync-%NEW_VER%-linux.tar.gz>> "%SYNC_DIR%\build\installer\checksums.txt"
    )
)
if defined ANDROID_APK if exist "%SYNC_DIR%\%ANDROID_APK%" (
    echo   Checksum: %ANDROID_APK%
    for /f "tokens=*" %%h in ('certutil -hashfile "%SYNC_DIR%\%ANDROID_APK%" SHA256 ^| findstr /v "hash" ^| findstr /v "CertUtil"') do (
        echo %%h  MinIOSync-%NEW_VER%.apk>> "%SYNC_DIR%\build\installer\checksums.txt"
    )
)

REM Git commit + tag (from minio_odoo_project root)
echo.
echo   Git commit + tag...
cd /d "%~dp0..\.."
git add minio_sync/pubspec.yaml minio_sync/scripts/installer.iss minio_sync/lib/version.dart
git commit -m "release: MinIO Sync v%NEW_VER%"
git tag -f "minio-sync-v%NEW_VER%"
echo   Pushing to origin...
git push origin main
git push origin "minio-sync-v%NEW_VER%" --force

REM Build asset list for gh release (using absolute paths)
set ASSETS=
if defined WIN_INSTALLER if exist "%SYNC_DIR%\%WIN_INSTALLER%" set ASSETS=%ASSETS% "%SYNC_DIR%\%WIN_INSTALLER%"
if defined LINUX_TAR if exist "%SYNC_DIR%\%LINUX_TAR%" set ASSETS=%ASSETS% "%SYNC_DIR%\%LINUX_TAR%"
if defined ANDROID_APK if exist "%SYNC_DIR%\%ANDROID_APK%" set ASSETS=%ASSETS% "%SYNC_DIR%\%ANDROID_APK%"
set ASSETS=%ASSETS% "%SYNC_DIR%\build\installer\checksums.txt"

echo.
echo   Creating GitHub release with assets...
echo   Assets: %ASSETS%
gh release create "minio-sync-v%NEW_VER%" %ASSETS% ^
    --title "MinIO Sync v%NEW_VER%" ^
    --notes "MinIO Sync v%NEW_VER% - Windows installer, Linux bundle, Android APK"

echo.
echo ============================================================
echo   DONE! Published MinIO Sync v%NEW_VER%
echo ============================================================
if defined WIN_INSTALLER echo   Windows: %WIN_INSTALLER%
if defined LINUX_TAR echo   Linux:   %LINUX_TAR%
if defined ANDROID_APK echo   Android: %ANDROID_APK%
echo   https://github.com/ThanhNhanDang/minio_odoo_project/releases
echo ============================================================
echo.
pause
