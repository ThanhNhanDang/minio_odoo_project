param(
    [string]$Password = "MinIOSync2024"
)

$certsDir = Join-Path $PSScriptRoot "certs"
$pfxPath = Join-Path $certsDir "minio-sync-signing.pfx"

if (-not (Test-Path $certsDir)) {
    New-Item -ItemType Directory -Path $certsDir | Out-Null
}

if (Test-Path $pfxPath) {
    Write-Host "[INFO] Certificate already exists: $pfxPath"
    exit 0
}

Write-Host "Creating self-signed code signing certificate..."

$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject "CN=MinIO Sync, O=ThanhNhanDang, L=Ho Chi Minh, C=VN" `
    -FriendlyName "MinIO Sync Code Signing" `
    -NotAfter (Get-Date).AddYears(5) `
    -CertStoreLocation Cert:\CurrentUser\My `
    -HashAlgorithm SHA256 `
    -KeyLength 2048 `
    -KeyUsage DigitalSignature `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")

$securePwd = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $securePwd | Out-Null

Write-Host "Thumbprint: $($cert.Thumbprint)"
Write-Host "Subject:    $($cert.Subject)"
Write-Host "Expiry:     $($cert.NotAfter)"
Write-Host ""
Write-Host "[OK] Certificate saved to: $pfxPath"
