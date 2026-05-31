# Tunnel Monitor — app icon (Liquid Glass)

Whimsical concept: a **traffic-light mascot** peeking from a **tunnel** (matches menu-bar green/yellow/red). Layered for **Icon Composer** (macOS 26 / Xcode 26); flat **`.icns`** for older macOS and the SPM build script.

## Files

| File | Purpose |
|------|---------|
| `Layers/01-background.svg` | Soft color blobs (glass depth) |
| `Layers/02-tunnel.svg` | Tunnel arch |
| `Layers/03-traffic-light.svg` | Lights + smile + sparkle |
| `../AppIcon-1024.png` | Flattened master (1024×1024) |
| `../AppIcon.icns` | Legacy icon (generated) |
| `../AppIcon.icon` | *(you create in Icon Composer)* → Liquid Glass |

## macOS 26 — Icon Composer (recommended)

1. Install **Icon Composer** (Xcode 26+ or [developer.apple.com/icon-composer](https://developer.apple.com/icon-composer/)).
2. New document → canvas **1024×1024** (Mac).
3. Import `Layers/01-background.svg`, `02-tunnel.svg`, `03-traffic-light.svg` as separate layers (back → front).
4. Tune Liquid Glass per layer (specular, blur, translucency). **Do not** bake shadows or outer masks — the system adds them.
5. Preview **Default**, **Dark**, and **Mono** (clear/tinted).
6. Save as `AppIcon.icon` next to this folder: `Resources/AppIcon.icon`.
7. In **TunnelMonitorXcode**, set the target **App Icon** to `AppIcon.icon`, or compile:

```bash
xcrun actool app/TunnelMonitor/Resources/AppIcon.icon \
  --compile build/icon-assets \
  --app-icon AppIcon \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --output-partial-info-plist /dev/null
```

8. Add `CFBundleIconName` = `AppIcon` in `Info.plist` (already set when using `.icon`).

Keep **`AppIcon.icns`** in the bundle for macOS 14–25.

## Regenerate `.icns` (SPM / `build-app.sh`)

```bash
cp /path/to/master-1024.png app/TunnelMonitor/Resources/AppIcon-1024.png
bash build/generate-app-icon.sh
```

## Design notes (HIG / Liquid Glass)

- **≤4 layer groups** in Icon Composer (Apple compiles reliably).
- **Bold shapes**, no fine text, no photoreal textures.
- **Whimsy** lives in the smile, sparkle, and “peeking” pose — keep lights readable at 32×32.
- Aligns with in-app **traffic-light** status (green / yellow / red).
