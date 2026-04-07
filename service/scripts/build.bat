@echo off
setlocal

pushd "%~dp0\.."

set VERSION=1.0.0
set BINARY=minio-service.exe

echo ==> Building %BINARY% v%VERSION%...

go build -ldflags="-s -w -H windowsgui -X main.version=%VERSION%" -o %BINARY% .\cmd\minio-service\

if %ERRORLEVEL% NEQ 0 (
    echo BUILD FAILED
    popd
    exit /b 1
)

echo ==> BUILD OK: %BINARY%
for %%A in (%BINARY%) do echo    Size: %%~zA bytes

popd
