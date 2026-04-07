@echo off
echo ============================================
echo   MinIO Sync - Dev Mode
echo ============================================
echo.

set PROJECT_DIR=%~dp0..
cd /d "%PROJECT_DIR%"

echo [*] Running in debug mode on Windows...
echo [*] Press Ctrl+C to stop, 'r' for hot reload, 'R' for hot restart
echo.

call D:\flutter\bin\flutter.bat run -d windows
