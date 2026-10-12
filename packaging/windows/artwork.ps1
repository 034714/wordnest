# Non-UI, original vector-like artwork. No third-party installer assets.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot 'artwork'
New-Item -ItemType Directory -Force $out | Out-Null
function New-WordNestImage([int]$width, [int]$height, [string]$name, [bool]$large) {
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#F2F8F5'))
    $green = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#30634D'))
    $soft = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#D8EBDD'))
    $pen = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml('#30634D'), 4)
    try {
        if ($large) { $cx = 82; $cy = 124; $radius = 58 } else { $cx = 29; $cy = 29; $radius = 25 }
        $g.FillEllipse($soft, $cx-$radius, $cy-$radius, $radius*2, $radius*2)
        # Open book / nest, topped by a growing leaf: original WordNest motif.
        $s = $radius / 58.0
        $points = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new($cx-38*$s,$cy+4*$s),
            [System.Drawing.PointF]::new($cx-19*$s,$cy+9*$s),
            [System.Drawing.PointF]::new($cx,$cy+23*$s),
            [System.Drawing.PointF]::new($cx+19*$s,$cy+9*$s),
            [System.Drawing.PointF]::new($cx+38*$s,$cy+4*$s))
        $pen.Width = 4*$s
        $g.DrawLines($pen, $points)
        $g.DrawArc($pen, $cx-38*$s, $cy-5*$s, 76*$s, 44*$s, 12, 156)
        $g.DrawLine($pen, $cx, $cy+20*$s, $cx, $cy-16*$s)
        $g.FillEllipse($green, $cx+1*$s, $cy-29*$s, 25*$s, 13*$s)
        if ($large) {
            $font = New-Object System.Drawing.Font('Segoe UI', 19, [System.Drawing.FontStyle]::Bold)
            $small = New-Object System.Drawing.Font('Segoe UI', 10)
            try {
                $g.DrawString('WordNest', $font, $green, 17, 220)
                $g.DrawString("A quiet place`nfor words to grow.", $small, $green, 19, 263)
                $g.DrawLine($pen, 20, 335, 144, 335)
            } finally { $font.Dispose(); $small.Dispose() }
        }
        $bitmap.Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Bmp)
    } finally { $pen.Dispose(); $green.Dispose(); $soft.Dispose(); $g.Dispose(); $bitmap.Dispose() }
}
New-WordNestImage 164 410 'wizard.bmp' $true
New-WordNestImage 58 58 'wizard-small.bmp' $false
