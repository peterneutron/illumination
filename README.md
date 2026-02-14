# Illumination
<img alt="Main View" src="assets/Illumination.png" />

---

Illumination is a powerful yet minimal macOS menu bar utility designed to unlock the full brightness potential of Apple XDR and other EDR-capable displays. It intelligently extends the SDR brightness range while respecting HDR content and adapting to your environment.

> ⚠️ Experimental project
>
> Expect rough edges, broken promises and ruined displays. Use at your own risk. If you need a production-ready tool, consider established alternatives. Some noteworthy ones are listed below.
>
> - [BrightIntosh](https://github.com/niklasr22/BrightIntosh)


## Features

- Auto-Detection of EDR capable displays. ⚠️ Only Built-In at the moment ⚠️
- Seamless System Integration: Works with macOS auto-brightness **ON**. Illumination only moves your brightness **while EDR is ON** and restores your pre‑EDR SDR level when EDR turns **OFF**.
-   **Calibrated Ambient Light Engine:**  
    Converts macOS’s raw `AmbientBrightness` (fixed‑point, driver‑internal) into **real‑world lux** with a power law (L = a·x^p), a **sun‑anchor** at ~120 klx, and a gated **day‑max blend** for robustness. It’s stable from dim rooms to direct sun. 

    The complete methodology is detailed in our [**technical paper**](assets/Algorithm.pdf).
- Extended Dynamic Range (EDR): Go beyond the standard SDR brightness limits.
- Ambient Light Sensing (ALS): Automatically toggles EDR and **scales headroom** based on ambient light. Profiles are tuned for **daylight** (e.g., shade → sun) with hysteresis to avoid cloud‑flicker: Twilight, Daybreak, Midday (default), Sunburst, High Noon.
- App Policy controls: `Master` (On/Off), `Mode` (Manual/Auto), `Scope` (Everywhere/Apps). In `Apps` scope, denylisted frontmost apps force Illumination off and previous state is restored when switching away.
- HDR-Aware Ducking: automatically reduces boost during HDR-like content. Currently treated as **experimental/debug-oriented** in this phase.
- Persistent HDR Tile: An optional, small video tile that can be placed in a corner of the screen to ensure EDR mode remains active, keeping EDR engaged within fullscreen applications/spaces.
- Debug submenu with extended diagnostics and fine-grained control settings.
- Debug ALS trace tooling: in-memory ring buffer capture, JSONL export, clear, and replay summary for deterministic investigations.

### Known limits
- Lux is capped at **120 000** to match observed ALS saturation.
- EDR can draw significant power at high nits.
- Built‑in displays only (for now).
- ALS `xDark` is intentionally pinned to **0.0** in the current model. This is preserved for compatibility and should be revisited with explicit recalibration experiments.
- `HDRRegionSampler` and HDR ducking remain experimental and primarily surfaced through Debug/Experimental controls.
- ALS trace/replay controls are intentionally Debug-only in this phase.
- Algorithm constants are split into three tiers: immutable decode/sentinel protocol constants, ALS hardware profile constants, and EDR policy profile constants.
- Current defaults are `HW_MBP16L23` (ALS hardware profile) and `EDR_MBP16L23` (EDR policy profile), selectable in Debug menu only.

## Getting Started: Building from Source

This project uses a `Makefile` to automate the build process.

#### 1. Prerequisites

- macOS with Xcode (26+ recommended) installed.
- XcodeGen (`xcodegen`) installed and available in `PATH`.
- SwiftLint (`swiftlint`) installed and available in `PATH` for lint/verify checks.
- Clone the repository:
  ```bash
  git clone https://github.com/peterneutron/illumination.git
  ```

#### 2. Generate and Verify the Xcode Project

- `make xcodegen` – generates `Illumination.xcodeproj` from `project.yml`.
- `make xcodegen-check` – verifies `Illumination.xcodeproj` is in sync with `project.yml`.

#### 3. Pick a Build Lane

The Makefile now exposes explicit lanes for unsigned, development-signed, and distribution builds. All artifacts land in `./build`.

- `make build` – unsigned local build (default). Running `make` with no target is equivalent.
- `make devsigned` – development-signed build using automatic signing. Deterministic overrides are supported with `SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" DEVELOPMENT_TEAM="TEAMID" make devsigned`. If not provided, `scripts/resolve-signing.sh` auto-detects a suitable identity (and falls back to `scripts/select_signing_identity.sh` when interactive selection is needed).
- `make archive` – manual-signing archive intended for maintainers. Runs signing resolution in non-interactive mode and fails fast if signing variables are not resolvable.
- `make export` – exports an `.app` from the latest archive using `ExportOptions.plist`.
- `make package` – zips the exported app into `build/Illumination.zip`.
- `make clean` – removes `./build`.
- `make lint` – runs SwiftLint safety/style checks with project config.
- `make test` – runs unit tests (`IlluminationTests`).
- `make verify` – runs `xcodegen-check`, `lint`, `build`, and `test`.

> The signing helper requires the Xcode command line tools and at least one Apple Development certificate in your login keychain.

## Contributor Verification Checklist

Before opening or merging a PR, run:

1. `make xcodegen-check`
2. `make build`
3. `make test`
4. `make lint` (requires `swiftlint`)
5. `make verify` (full gate)

## Acknowledgments

- [BrightIntosh](https://github.com/niklasr22/BrightIntosh)
- Google Gemini and OpenAI GPT families of models and all the labs involved making these possible 🙏
