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
- HDR-Aware Ducking: A standout feature that automatically reduces the brightness boost when HDR content is detected. This preserves the creative intent of HDR media without requiring manual intervention. ⚠️ Partially working ⚠️
- Persistent HDR Tile: An optional, small video tile that can be placed in a corner of the screen to ensure EDR mode remains active, keeping EDR engaged within fullscreen applications/spaces.
- Debug submenu with extended diagnostics and fine-grained control settings.

### Known limits
- Lux is capped at **120 000** to match observed ALS saturation.
- EDR can draw significant power at high nits.
- Built‑in displays only (for now).

## Getting Started: Building from Source

This project uses a `Makefile` to automate the build process.

#### 1. Prerequisites

- macOS with Xcode (26+ recommended) installed.
- Clone the repository:
  ```bash
  git clone https://github.com/peterneutron/illumination.git
  ```

#### 2. One-Time Setup in Xcode

Before you can build from the command line, you need to configure code signing once in Xcode.

1.  Open `Illumination.xcodeproj` in Xcode.
2.  In the project navigator, select the "Illumination" project, then the "Illumination" target.
3.  Go to the **"Signing & Capabilities"** tab.
4.  From the **"Team"** dropdown, select your personal Apple ID. Xcode will automatically create a local development certificate for you.
5.  You can now close Xcode.

#### 3. Pick a Build Lane

The Makefile now exposes explicit lanes for unsigned, development-signed, and distribution builds. All artifacts land in `./build`.

- `make build` – unsigned local build (default). Running `make` with no target is equivalent.
- `make devsigned` – development-signed build using automatic signing. Provide a certificate explicitly with `SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" make devsigned`, or leave it unset to launch `scripts/select_signing_identity.sh`, which will discover certificates via the `security` tool and prompt you to choose.
- `make archive` – manual-signing archive intended for maintainers. Accepts the same `SIGNING_IDENTITY` variable and falls back to the helper script if needed.
- `make export` – exports an `.app` from the latest archive using `ExportOptions.plist`.
- `make package` – zips the exported app into `build/Illumination.zip`.
- `make clean` – removes `./build`.

> The signing helper requires the Xcode command line tools and at least one Apple Development certificate in your login keychain.

## Acknowledgments

- [BrightIntosh](https://github.com/niklasr22/BrightIntosh)
- Google Gemini and OpenAI GPT families of models and all the labs involved making these possible 🙏
