# Illumination
<img alt="Main View" src="assets/Illumination.png" />

---

Illumination is a minimal macOS menu bar app that extends display brightness on XDR‑capable Macs by engaging EDR and lifting SDR via gamma.

> ⚠️ Experimental project
>
> Expect rough edges, broken promises and ruined displays. Use at your own risk. If you need a production-ready tool, consider established alternatives. Some noteworthy ones are listed below.
>
> - [BrightIntosh](https://github.com/niklasr22/BrightIntosh)


## Features
- Menu bar app with Enabled checkbox and 0–100% brightness slider (percent‑based intent).
- EDR overlay to keep the system in HDR/EDR mode.
- Optional HDR tile overlay (corner or fullscreen) to help pin EDR in native fullscreen Spaces.
- Debug submenu with basic diagnostics and overlay/tile toggles.

## Build
- Requirements: Xcode (26+ recommended) and an EDR‑capable display.
- Create archive: `build/Illumination.xcarchive`
  - `make archive`
- Export from archive using `ExportOptions.plist` into `build/`:
  - `make export`

## Notes
- The export step uses `Illumination/ExportOptions.plist` (`method=debugging`, `signingStyle=automatic`). Ensure signing is configured in Xcode.