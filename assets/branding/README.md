# App icon and splash artwork

Source: `PecaOne_AppIcon.png` (unchanged user-provided artwork).

Regenerate on Windows with `./scripts/generate-app-icons.ps1`.

- Launcher icons crop 7% from each edge, retaining the lettering.
- Android 8+ uses an adaptive icon: the generator removes the warm-white matte
  and places the artwork inside the centered 66dp safe circle on a 108dp layer.
  It also generates the monochrome layer used by themed icons. The legacy
  density-specific launcher PNGs remain as the fallback for older Android.
- Splash artwork crops 5% from each edge independently of the launcher.
- Android 12+ uses a single 1152px PNG (288dp at xxxhdpi) with 640px
  (160dp) centered artwork. Padding is part of the image itself so system
  drawable resizing cannot discard it. The content must fit the 768px
  (192dp) circular safe area.
- Earlier Android versions and iOS show the splash artwork at 240dp/pt.
- Output is opaque RGB, including the 1024px iOS App Store icon.
