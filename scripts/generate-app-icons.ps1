$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repoRoot = Split-Path $PSScriptRoot -Parent
$sourcePath = Join-Path $repoRoot 'assets/branding/PecaOne_AppIcon.png'
$source = [System.Drawing.Image]::FromFile($sourcePath)
function Write-Icon([string]$relativePath, [int]$size, [double]$cropFraction = 0.07, [int]$artworkSize = 0) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        # Launcher and splash use independent crops; splash padding is baked into the PNG.
        $crop = [System.Drawing.RectangleF]::new(
            [single]($source.Width * $cropFraction), [single]($source.Height * $cropFraction),
            [single]($source.Width * (1 - 2 * $cropFraction)), [single]($source.Height * (1 - 2 * $cropFraction)))
        if ($artworkSize -eq 0) { $artworkSize = $size }
        $offset = [single](($size - $artworkSize) / 2)
        $graphics.DrawImage($source, [System.Drawing.RectangleF]::new($offset, $offset, $artworkSize, $artworkSize), $crop, [System.Drawing.GraphicsUnit]::Pixel)
        $bitmap.Save((Join-Path $repoRoot $relativePath), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}
function Write-AdaptiveIcons {
    # Android adaptive icons use a 108dp layer, with the logo kept inside the
    # centered 66dp safe circle. At xxxhdpi that is 432px and 264px respectively.
    $canvasSize = 432
    $artworkWidth = 212 # 53dp
    $artworkHeight = 222 # 55.5dp; a slight vertical adjustment keeps the full logo inside the safe circle.
    $offsetX = [int](($canvasSize - $artworkWidth) / 2)
    $offsetY = [int](($canvasSize - $artworkHeight) / 2)
    $sourceArtwork = [System.Drawing.Bitmap]::new($artworkWidth, $artworkHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($sourceArtwork)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $crop = [System.Drawing.RectangleF]::new(
            [single]($source.Width * 0.07), [single]($source.Height * 0.07),
            [single]($source.Width * 0.86), [single]($source.Height * 0.86))
        $target = [System.Drawing.RectangleF]::new(0, 0, [single]$artworkWidth, [single]$artworkHeight)
        $graphics.DrawImage($source, $target, $crop, [System.Drawing.GraphicsUnit]::Pixel)
    } finally {
        $graphics.Dispose()
    }

    $foreground = [System.Drawing.Bitmap]::new($canvasSize, $canvasSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $monochrome = [System.Drawing.Bitmap]::new($canvasSize, $canvasSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        # The source is artwork on a warm white background. Remove that matte
        # while recovering antialiased edge colors for a clean transparent layer.
        $background = @(253, 251, 243)
        for ($y = 0; $y -lt $artworkHeight; $y++) {
            for ($x = 0; $x -lt $artworkWidth; $x++) {
                $pixel = $sourceArtwork.GetPixel($x, $y)
                $alpha = [Math]::Max(
                    [Math]::Abs($pixel.R - $background[0]) / [double]$background[0],
                    [Math]::Max(
                        [Math]::Abs($pixel.G - $background[1]) / [double]$background[1],
                        [Math]::Abs($pixel.B - $background[2]) / [double]$background[2]))
                if ($alpha -lt 0.05) { continue }

                $alpha = [Math]::Min(1.0, $alpha)
                $alphaByte = [int][Math]::Round($alpha * 255)
                $red = [int][Math]::Max(0, [Math]::Min(255, [Math]::Round(($pixel.R - (1 - $alpha) * $background[0]) / $alpha)))
                $green = [int][Math]::Max(0, [Math]::Min(255, [Math]::Round(($pixel.G - (1 - $alpha) * $background[1]) / $alpha)))
                $blue = [int][Math]::Max(0, [Math]::Min(255, [Math]::Round(($pixel.B - (1 - $alpha) * $background[2]) / $alpha)))
                $foreground.SetPixel($offsetX + $x, $offsetY + $y, [System.Drawing.Color]::FromArgb($alphaByte, $red, $green, $blue))
                $monochrome.SetPixel($offsetX + $x, $offsetY + $y, [System.Drawing.Color]::FromArgb($alphaByte, 255, 255, 255))
            }
        }
        $directory = Join-Path $repoRoot 'android/app/src/main/res/drawable-xxxhdpi'
        $foreground.Save((Join-Path $directory 'ic_launcher_foreground.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $monochrome.Save((Join-Path $directory 'ic_launcher_monochrome.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $sourceArtwork.Dispose()
        $foreground.Dispose()
        $monochrome.Dispose()
    }
}
try {
    $densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
    foreach ($density in $densities.Keys) {
        Write-Icon "android/app/src/main/res/mipmap-$density/ic_launcher.png" $densities[$density]
    }
    Write-AdaptiveIcons
    $splashDirectory = Join-Path $repoRoot 'android/app/src/main/res/drawable-xxxhdpi'
    New-Item -ItemType Directory -Force $splashDirectory | Out-Null
    Write-Icon 'android/app/src/main/res/drawable-xxxhdpi/splash_logo.png' 704 0.05
    # Android 12: 288dp canvas, 160dp artwork, 192dp circular safe area.
    Write-Icon 'android/app/src/main/res/drawable-xxxhdpi/splash_icon.png' 1152 0.05 640
    foreach ($scale in 1..3) {
        $suffix = if ($scale -eq 1) { '' } else { "@${scale}x" }
        Write-Icon "ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage$suffix.png" (240 * $scale) 0.05
    }
    $catalog = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    $contents = Get-Content (Join-Path $repoRoot "$catalog/Contents.json") -Raw | ConvertFrom-Json
    foreach ($icon in ($contents.images | Sort-Object filename -Unique)) {
        $size = [int]([double]($icon.size.Split('x')[0]) * [double]($icon.scale.TrimEnd('x')))
        Write-Icon "$catalog/$($icon.filename)" $size
    }
} finally {
    $source.Dispose()
}
Write-Output 'Generated Android and iOS app icons.'
