# Illumination

Illumination is a minimal macOS menu bar app that extends display brightness on XDR‑capable Macs by engaging EDR and lifting SDR via gamma.

```
⚠️ Experimental ⚠️

Expect rough edges, broken promises and ruined displays. Use at your own risk.
````

Features
- Menu bar app with Enabled checkbox and 0–100% brightness slider (percent‑based intent).
- EDR overlay to keep the system in HDR/EDR mode.
- Optional HDR tile overlay (corner or fullscreen) to help pin EDR in native fullscreen Spaces.
- Debug submenu with basic diagnostics and overlay/tile toggles.

Build
- Requirements: Xcode (14+ recommended) and an EDR‑capable display.
- Create archive: `build/Illumination.xcarchive`
  - `make archive`
- Export from archive using `ExportOptions.plist` into `build/export/`:
  - `make export`

Notes
- The export step uses `Illumination/ExportOptions.plist` (`method=debugging`, `signingStyle=automatic`). Ensure signing is configured in Xcode.