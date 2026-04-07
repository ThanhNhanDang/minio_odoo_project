@echo off
REM Setup: download dependencies and prepare for build
setlocal

pushd "%~dp0\.."

echo ==> Checking Go installation...
where go >nul 2>&1
if errorlevel 1 (
    echo ERROR: Go is not installed. Download from https://go.dev/dl/
    popd
    exit /b 1
)

for /f "tokens=*" %%i in ('go version') do echo ==> %%i

echo ==> Downloading dependencies...
go mod tidy
if errorlevel 1 (popd & exit /b 1)

echo ==> Verifying build...
go build ./...
if errorlevel 1 (popd & exit /b 1)

popd
echo.
echo Setup complete! Run 'scripts\dev.bat' to start development server.
