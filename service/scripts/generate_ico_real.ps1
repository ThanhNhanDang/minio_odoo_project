Add-Type -AssemblyName System.Drawing
$inFile = 'd:\workspaces\odoo\extra-addons-17\minio_odoo_project\service\internal\tray\icon.png'
$outFile = 'd:\workspaces\odoo\extra-addons-17\minio_odoo_project\service\internal\tray\icon.ico'

$img = [System.Drawing.Image]::FromFile($inFile)
$bmp = New-Object System.Drawing.Bitmap(64, 64)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($img, 0, 0, 64, 64)
$g.Dispose()

$hIcon = $bmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hIcon)
$fs = [System.IO.File]::Create($outFile)
$icon.Save($fs)
$fs.Close()
$icon.Dispose()
$bmp.Dispose()
$img.Dispose()
[System.Runtime.InteropServices.Marshal]::DestroyIcon($hIcon)

Write-Host "Real .ico created!"
