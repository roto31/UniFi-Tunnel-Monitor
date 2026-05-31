# Tunnel Monitor — app icon (Liquid Glass)

Whimsical **traffic-light mascot** in a **tunnel** (menu-bar green/yellow/red semantics). Built automatically with **Xcode `actool`** (no manual Icon Composer session required).

## Automated build (recommended)

```bash
# Master artwork (1024×1024) + actool → AppIcon.icon, Assets.car, AppIcon.icns
bash build/generate-liquid-glass-icon.sh
bash build/build-app.sh
```

`build-app.sh` runs the icon script by default (set `TM_SKIP_LIQUID_GLASS=1` to skip).

| Output | Purpose |
|--------|---------|
| `AppIcon.icon/` | Generated Icon Composer bundle (`icon.json` + `Assets/`) |
| `Assets.car` | Liquid Glass catalog for **macOS 26+** (`CFBundleIconName` = `AppIcon`) |
| `AppIcon.icns` | Fallback for **macOS 14–25** (`CFBundleIconFile`) |
| `AppIcon-1024.png` | Source composite (committed) |

### Modes

```bash
# Default: full approved composite on glass (best match to marketing art)
bash build/generate-liquid-glass-icon.sh

# Alternate: three rasterized SVG layers (background, tunnel, traffic-light)
TM_ICON_MODE=layered bash build/generate-liquid-glass-icon.sh
```

### Tools used

| Tool | Role |
|------|------|
| `qlmanage` | Rasterize `Layers/*.svg` when `TM_ICON_MODE=layered` |
| `xcrun actool` | Compile `AppIcon.icon` → `Assets.car` + `AppIcon.icns` |
| `ictool` | Optional preview PNG (Icon Composer.app) |

Requires **Xcode 26+** on the build Mac.

## Source layers (optional edit)

| File | Role |
|------|------|
| `Layers/01-background.svg` | Soft depth blobs |
| `Layers/02-tunnel.svg` | Tunnel arch |
| `Layers/03-traffic-light.svg` | Lights + smile + sparkle |
| `../AppIcon-1024.png` | Flat composite (drives `composite` mode) |

Regenerate flat `.icns` only:

```bash
bash build/generate-app-icon.sh
```

## Manual tweak (optional)

Open the generated `../AppIcon.icon` in **Icon Composer** to adjust specular/blur per layer, then re-run:

```bash
bash build/generate-liquid-glass-icon.sh
```

Or save manual edits and run with `SKIP_ICON_COMPILE=1` then compile yourself:

```bash
SKIP_ICON_COMPILE=1 bash build/generate-liquid-glass-icon.sh
xcrun actool app/TunnelMonitor/Resources/AppIcon.icon \
  --compile build/icon-compile --app-icon AppIcon \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --output-partial-info-plist build/icon-compile/partial.plist
```

## Design notes

- ≤4 layer groups in `icon.json` (Apple compiles reliably).
- Bold shapes; no baked shadows (system adds glass).
- Aligns with in-app traffic-light status colors.
