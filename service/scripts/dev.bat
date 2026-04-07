@echo off
REM Build and run the service in development mode
setlocal

pushd "%~dp0\.."

echo ==> Building minio-service...
go build -o minio-service.exe .\cmd\minio-service
if errorlevel 1 (
    echo BUILD FAILED
    popd
    exit /b 1
)

echo ==> Starting minio-service (port 9999)...
echo ==> Press Ctrl+C to stop
minio-service.exe %*

popd
