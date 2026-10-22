param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [switch]$AndroidLauncherOnly
)

Add-Type -AssemblyName System.Drawing
$sourcePath = Join-Path $ProjectRoot 'assets/logos/brand_mark.png'
$source = [System.Drawing.Bitmap]::new($sourcePath)
try {
  $minX = $source.Width; $minY = $source.Height; $maxX = 0; $maxY = 0
  for ($y = 0; $y -lt $source.Height; $y += 2) {
    for ($x = 0; $x -lt $source.Width; $x += 2) {
      if ($source.GetPixel($x, $y).A -gt 16) {
        $minX = [Math]::Min($minX, $x); $minY = [Math]::Min($minY, $y)
        $maxX = [Math]::Max($maxX, $x); $maxY = [Math]::Max($maxY, $y)
      }
    }
  }
  if ($minX -ge $maxX -or $minY -ge $maxY) { throw 'Brand mark is empty' }
  $bounds = [System.Drawing.Rectangle]::new($minX, $minY, $maxX - $minX + 1, $maxY - $minY + 1)

  function Save-BrandIcon([string]$path, [int]$size, [bool]$opaque) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size)
    try {
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.Clear($(if ($opaque) { [System.Drawing.Color]::FromArgb(255, 246, 250, 248) } else { [System.Drawing.Color]::Transparent }))
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        # Android launcher masks can crop artwork placed near the edge. Keep the
        # mark within the visual safe area so it has the same breathing room as
        # system icons on circular, squircle, and rounded-square launchers.
        $length = [int][Math]::Round($size * 0.48)
        $offset = [int][Math]::Floor(($size - $length) / 2)
        $destination = [System.Drawing.Rectangle]::new($offset, $offset, $length, $length)
        $graphics.DrawImage($source, $destination, $bounds, [System.Drawing.GraphicsUnit]::Pixel)
      } finally { $graphics.Dispose() }
      $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
  }

  $android = Join-Path $ProjectRoot 'android/app/src/main/res'
  foreach ($item in @(@('mdpi',48),@('hdpi',72),@('xhdpi',96),@('xxhdpi',144),@('xxxhdpi',192))) {
    $folder = Join-Path $android ('mipmap-' + $item[0])
    Save-BrandIcon (Join-Path $folder 'ic_launcher.png') ([int]$item[1]) $true
    if (-not $AndroidLauncherOnly) {
      Save-BrandIcon (Join-Path $folder 'launch_image.png') ([int]$item[1] * 3) $false
    }
  }
  if ($AndroidLauncherOnly) { return }

  $ios = Join-Path $ProjectRoot 'ios/Runner/Assets.xcassets'
  $iconFolder = Join-Path $ios 'AppIcon.appiconset'
  $manifest = Get-Content (Join-Path $iconFolder 'Contents.json') -Raw | ConvertFrom-Json
  foreach ($entry in $manifest.images) {
    if (-not $entry.filename) { continue }
    $points = [double]($entry.size.Split('x')[0])
    $scale = [int]($entry.scale.TrimEnd('x'))
    Save-BrandIcon (Join-Path $iconFolder $entry.filename) ([int][Math]::Round($points * $scale)) $true
  }
  $launch = Join-Path $ios 'LaunchImage.imageset'
  foreach ($scale in 1..3) {
    $name = if ($scale -eq 1) { 'LaunchImage.png' } else { "LaunchImage@${scale}x.png" }
    Save-BrandIcon (Join-Path $launch $name) (168 * $scale) $false
  }

  $mac = Join-Path $ProjectRoot 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
  foreach ($size in @(16,32,64,128,256,512,1024)) {
    Save-BrandIcon (Join-Path $mac "app_icon_$size.png") $size $true
  }

  $web = Join-Path $ProjectRoot 'web'
  Save-BrandIcon (Join-Path $web 'favicon.png') 48 $true
  foreach ($size in @(192,512)) {
    Save-BrandIcon (Join-Path $web "icons/Icon-$size.png") $size $true
    Save-BrandIcon (Join-Path $web "icons/Icon-maskable-$size.png") $size $true
  }

  $icoPath = Join-Path $ProjectRoot 'windows/runner/resources/app_icon.ico'
  $frames = @()
  foreach ($size in @(16,32,48,256)) {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("muthbat-icon-$size-$PID.png")
    Save-BrandIcon $temp $size $true
    $frames += @{ size = $size; bytes = [System.IO.File]::ReadAllBytes($temp) }
    Remove-Item -LiteralPath $temp
  }
  $stream = [System.IO.File]::Create($icoPath)
  try {
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
      $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
      $offset = 6 + 16 * $frames.Count
      foreach ($frame in $frames) {
        $writer.Write([byte]($frame.size % 256)); $writer.Write([byte]($frame.size % 256))
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$frame.bytes.Length); $writer.Write([uint32]$offset)
        $offset += $frame.bytes.Length
      }
      foreach ($frame in $frames) { $writer.Write([byte[]]$frame.bytes) }
    } finally { $writer.Dispose() }
  } finally { $stream.Dispose() }
} finally { $source.Dispose() }
