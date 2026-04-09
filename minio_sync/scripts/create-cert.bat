@echo off
REM ============================================================
REM  Create self-signed code signing certificate for MinIO Sync
REM  Run ONCE as Administrator, then reuse the .pfx for signing.
REM
REM  Output: scripts\certs\minio-sync-signing.pfx
REM ============================================================

cd /d "%~dp0"

if not exist "certs" mkdir certs

REM --- Check if certificate already exists ---
if exist "certs\minio-sync-signing.pfx" (
    echo [INFO] Certificate already exists: certs\minio-sync-signing.pfx
    echo [INFO] Delete it first if you want to regenerate.
    pause
    exit /b 0
)

echo.
echo ============================================================
echo   Creating self-signed code signing certificate
echo ============================================================
echo.

REM --- Prompt for password ---
set /p CERT_PASS="Enter password for the certificate: "
if "%CERT_PASS%"=="" (
    echo [ERROR] Password cannot be empty.
    pause
    exit /b 1
)

REM --- Create self-signed certificate ---
REM   - Type: CodeSigningCert (Extended Key Usage = Code Signing)
REM   - Valid for 5 years
REM   - Stored in CurrentUser\My certificate store
powershell -NoProfile -Command ^
  "$cert = New-SelfSignedCertificate ^
    -Type CodeSigningCert ^
    -Subject 'CN=MinIO Sync, O=ThanhNhanDang, L=Ho Chi Minh, C=VN' ^
    -FriendlyName 'MinIO Sync Code Signing' ^
    -NotAfter (Get-Date).AddYears(5) ^
    -CertStoreLocation Cert:\CurrentUser\My ^
    -HashAlgorithm SHA256 ^
    -KeyLength 2048 ^
    -KeyUsage DigitalSignature ^
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3'); ^
  $pwd = ConvertTo-SecureString -String '%CERT_PASS%' -Force -AsPlainText; ^
  Export-PfxCertificate -Cert $cert -FilePath '%~dp0certs\minio-sync-signing.pfx' -Password $pwd | Out-Null; ^
  Write-Host 'Thumbprint:' $cert.Thumbprint; ^
  Write-Host 'Subject:' $cert.Subject; ^
  Write-Host 'Expiry:' $cert.NotAfter"

if not exist "certs\minio-sync-signing.pfx" (
    echo.
    echo [ERROR] Certificate creation failed!
    pause
    exit /b 1
)

REM --- Save password hint ---
echo Certificate password is required for signing. Store it securely.> "certs\README.txt"
echo DO NOT commit the .pfx file or password to git.>> "certs\README.txt"

echo.
echo ============================================================
echo   Certificate created successfully!
echo   File: scripts\certs\minio-sync-signing.pfx
echo.
echo   IMPORTANT:
echo   1. Set environment variable for publish.bat:
echo      set SIGN_CERT_PASS=your_password
echo   2. NEVER commit the .pfx file to git
echo ============================================================
echo.
pause
