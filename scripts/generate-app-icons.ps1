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
try {
    $densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
    foreach ($density in $densities.Keys) {
        Write-Icon "android/app/src/main/res/mipmap-$density/ic_launcher.png" $densities[$density]
    }
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
