<#
.SYNOPSIS
    Builds ISO2HD.exe, a launcher that opens the ISO2HD GUI without a console window.

.DESCRIPTION
    Compiles launcher\Launcher.cs with the .NET Framework 4 C# compiler that ships with Windows.
    The exe requests Administrator rights, then runs ISO2HD.ps1 from its own folder. If the exe
    is copied somewhere without the script, it runs the copy of ISO2HD.ps1 embedded here at
    build time - so re-run this script after changing ISO2HD.ps1.

    launcher\ISO2HD.ico is generated on the first build; delete it to regenerate.
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path $PSScriptRoot 'ISO2HD.exe')
)
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'launcher'
$script = Join-Path $PSScriptRoot 'ISO2HD.ps1'
$ico = Join-Path $src 'ISO2HD.ico'

function New-Iso2hdIcon {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing
    $sizes = @(256, 48, 32, 16)
    $pngs = foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $k = $s / 256.0

        # Disc, partly inserted into the drive below it.
        $cx = 128 * $k; $cy = 96 * $k; $r = 84 * $k
        $discRect = New-Object System.Drawing.RectangleF(($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
        $discBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($discRect,
            [System.Drawing.Color]::FromArgb(245, 248, 252), [System.Drawing.Color]::FromArgb(150, 168, 196), 45.0)
        $g.FillEllipse($discBrush, $discRect)
        $rim = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 105, 130), [single][Math]::Max(1, 5 * $k))
        $g.DrawEllipse($rim, $discRect)
        $hub = 30 * $k
        $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 210, 228))), ($cx - $hub), ($cy - $hub), (2 * $hub), (2 * $hub))
        $hole = 12 * $k
        $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 70, 90))), ($cx - $hole), ($cy - $hole), (2 * $hole), (2 * $hole))

        # Drive body.
        $x = 14 * $k; $y = 136 * $k; $w = 228 * $k; $h = 104 * $k; $rad = [Math]::Max(2, 22 * $k)
        $body = New-Object System.Drawing.Drawing2D.GraphicsPath
        $body.AddArc($x, $y, 2 * $rad, 2 * $rad, 180, 90)
        $body.AddArc($x + $w - 2 * $rad, $y, 2 * $rad, 2 * $rad, 270, 90)
        $body.AddArc($x + $w - 2 * $rad, $y + $h - 2 * $rad, 2 * $rad, 2 * $rad, 0, 90)
        $body.AddArc($x, $y + $h - 2 * $rad, 2 * $rad, 2 * $rad, 90, 90)
        $body.CloseFigure()
        $bodyBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.RectangleF($x, $y, $w, $h)),
            [System.Drawing.Color]::FromArgb(78, 90, 114), [System.Drawing.Color]::FromArgb(34, 40, 54), 90.0)
        $g.FillPath($bodyBrush, $body)
        if ($s -ge 32) {
            $slot = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(20, 24, 32), [single][Math]::Max(1, 6 * $k))
            $g.DrawLine($slot, (40 * $k), (170 * $k), (216 * $k), (170 * $k))
        }
        $led = [Math]::Max(2, 14 * $k)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(90, 225, 130))),
            (206 * $k - $led / 2), (208 * $k - $led / 2), $led, $led)

        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        , $ms.ToArray()
    }

    # ICO container with PNG-compressed images (supported since Windows Vista).
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dim = [byte]($sizes[$i] % 256)
            $bw.Write($dim); $bw.Write($dim); $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($p in $pngs) { $bw.Write($p) }
    } finally {
        $bw.Dispose()
    }
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'The .NET Framework 4 C# compiler (csc.exe) was not found.' }
if (-not (Test-Path $script)) { throw "ISO2HD.ps1 not found at $script" }

if (-not (Test-Path $ico)) {
    New-Iso2hdIcon -Path $ico
    Write-Host "Created icon $ico"
}

& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
    "/out:$OutFile" "/win32manifest:$(Join-Path $src 'app.manifest')" "/win32icon:$ico" `
    "/resource:$script,ISO2HD.ps1" /r:System.Windows.Forms.dll "$(Join-Path $src 'Launcher.cs')"
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE." }

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script).Hash.Substring(0, 12)
Write-Host "Built $OutFile (embedded ISO2HD.ps1 SHA-256 $hash...)"
