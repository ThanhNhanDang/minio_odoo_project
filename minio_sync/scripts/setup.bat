@echo off
echo ============================================
echo   MinIO Sync - Setup
echo ============================================
echo.

:: Check Flutter
echo [1/3] Checking Flutter installation...
D:\flutter\bin\flutter.bat --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Flutter not found at D:\flutter
    echo         Download from: https://flutter.dev/docs/get-started/install
    exit /b 1
)
echo [OK] Flutter found

:: Check Visual Studio
echo [2/3] Checking Visual Studio...
D:\flutter\bin\flutter.bat doctor --verbose 2>&1 | findstr /C:"Visual Studio" | findstr /C:"[" >nul
echo [OK] Visual Studio check done

:: Get dependencies
echo [3/3] Getting dependencies...
cd /d "%~dp0.."
call D:\flutter\bin\flutter.bat pub get
if %ERRORLEVEL% neq 0 (
    echo [ERROR] flutter pub get failed
    exit /b 1
)

echo.
echo ============================================
echo   SETUP COMPLETE
echo ============================================
echo   Run 'scripts\dev.bat' to start development
echo   Run 'scripts\build.bat' to build release
echo ============================================
