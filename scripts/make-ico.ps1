# make-ico.ps1 — build stools.ico from logo.png.
#
# Produces a classic multi-resolution ICO with 32-bit BGRA DIB frames (NOT
# PNG-compressed), because CreateIconFromResourceEx — used by both the window
# icon path (window.sig) and the in-GUI IconTexture.initFromIco (render/icon.sig)
# — is most reliable with uncompressed DIB frames. Includes the large Windows 11
# sizes (up to 256) so jumbo/large-icon views and the taskbar look crisp.
#
# Usage:  pwsh -File scripts/make-ico.ps1

param(
    [string]$Source = "$PSScriptRoot\..\logo.png",
    [string]$Out    = "$PSScriptRoot\..\src\stools.ico"
)

Add-Type -AssemblyName System.Drawing

# Full size ladder. Windows 11 large/jumbo icon views use 96/256; keep the
# small ones for the titlebar (16) and taskbar (24/32/48).
$sizes = @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256)

$src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Source))

# Build one 32-bit BGRA bottom-up DIB frame (BITMAPINFOHEADER + BGRA + AND mask).
function New-DibFrame([System.Drawing.Bitmap]$srcBmp, [int]$s) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($srcBmp, 0, 0, $s, $s)
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter -ArgumentList $ms

    # BITMAPINFOHEADER (40 bytes). Height is doubled: color + AND mask.
    $bw.Write([UInt32]40)        # biSize
    $bw.Write([Int32]$s)         # biWidth
    $bw.Write([Int32]($s * 2))   # biHeight (color rows + mask rows)
    $bw.Write([UInt16]1)         # biPlanes
    $bw.Write([UInt16]32)        # biBitCount
    $bw.Write([UInt32]0)         # biCompression = BI_RGB
    $bw.Write([UInt32]0)         # biSizeImage (0 ok for BI_RGB)
    $bw.Write([Int32]0)          # biXPelsPerMeter
    $bw.Write([Int32]0)          # biYPelsPerMeter
    $bw.Write([UInt32]0)         # biClrUsed
    $bw.Write([UInt32]0)         # biClrImportant

    # BGRA color data, bottom-up rows.
    for ($y = $s - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $s; $x++) {
            $px = $bmp.GetPixel($x, $y)
            $bw.Write([Byte]$px.B)
            $bw.Write([Byte]$px.G)
            $bw.Write([Byte]$px.R)
            $bw.Write([Byte]$px.A)
        }
    }

    # 1-bpp AND mask: all zero (we rely on the alpha channel). Rows are padded
    # to a 32-bit boundary.
    $maskRowBytes = [Math]::Floor((($s + 31) / 32)) * 4
    for ($y = 0; $y -lt $s; $y++) {
        for ($b = 0; $b -lt $maskRowBytes; $b++) { $bw.Write([Byte]0) }
    }

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose(); $bmp.Dispose()
    return ,$bytes
}

$frames = @()
foreach ($s in $sizes) { $frames += , (New-DibFrame $src $s) }
$src.Dispose()

# Assemble the ICO container.
$stream = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter -ArgumentList $stream
$count = $sizes.Count
$bw.Write([UInt16]0)      # reserved
$bw.Write([UInt16]1)      # type = icon
$bw.Write([UInt16]$count) # image count

$offset = 6 + (16 * $count)
for ($i = 0; $i -lt $count; $i++) {
    $s = $sizes[$i]
    $data = $frames[$i]
    $dim = if ($s -ge 256) { 0 } else { $s }  # 0 means 256 in the dir entry
    $bw.Write([Byte]$dim)            # width
    $bw.Write([Byte]$dim)            # height
    $bw.Write([Byte]0)               # palette count
    $bw.Write([Byte]0)               # reserved
    $bw.Write([UInt16]1)             # planes
    $bw.Write([UInt16]32)            # bpp
    $bw.Write([UInt32]$data.Length)  # image byte size
    $bw.Write([UInt32]$offset)       # image offset
    $offset += $data.Length
}
foreach ($data in $frames) { $bw.Write($data) }
$bw.Flush()

$outPath = [System.IO.Path]::GetFullPath($Out)
[System.IO.File]::WriteAllBytes($outPath, $stream.ToArray())
$bw.Dispose(); $stream.Dispose()

$finalSize = ([System.IO.FileInfo]$outPath).Length
Write-Output ("wrote {0} ({1} bytes; sizes: {2})" -f $outPath, $finalSize, ($sizes -join ','))
