param([string]$Out = (Join-Path $PSScriptRoot "override.ico"))
# Generates the desktop app logo: a green Omega ("override") on a dark rounded tile.
Add-Type -AssemblyName System.Drawing

$sz = 256
$bmp = New-Object System.Drawing.Bitmap $sz, $sz
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$g.Clear([System.Drawing.Color]::FromArgb(0,0,0,0))

# rounded tile
$pad = 16; $r = 52
$rect = New-Object System.Drawing.Rectangle $pad, $pad, ($sz - 2*$pad), ($sz - 2*$pad)
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc($rect.X, $rect.Y, $r, $r, 180, 90)
$path.AddArc($rect.Right - $r, $rect.Y, $r, $r, 270, 90)
$path.AddArc($rect.Right - $r, $rect.Bottom - $r, $r, $r, 0, 90)
$path.AddArc($rect.X, $rect.Bottom - $r, $r, $r, 90, 90)
$path.CloseFigure()
$g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,0,16,7))), $path)
$g.DrawPath((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255,0,255,102)), 9), $path)

# Omega glyph with a soft green glow
$glyph = [string][char]0x03A9
$font = New-Object System.Drawing.Font "Segoe UI Symbol", 150, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center
$mid = New-Object System.Drawing.RectangleF 0, 8, $sz, $sz
$glow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60,0,255,102))
foreach ($d in @(-4,-2,2,4)) {
  $gr = New-Object System.Drawing.RectangleF $d, (8 + $d), $sz, $sz
  $g.DrawString($glyph, $font, $glow, $gr, $sf)
}
$g.DrawString($glyph, $font, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,0,255,102))), $mid, $sf)
$g.Dispose()

$hicon = $bmp.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hicon)
$fs = [System.IO.File]::Open($Out, [System.IO.FileMode]::Create)
$icon.Save($fs)
$fs.Close()
$icon.Dispose(); $bmp.Dispose()
Write-Host ("icon written: " + $Out) -ForegroundColor Green
