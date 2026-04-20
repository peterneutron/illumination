# Contract and Architecture

This document holds the durable architecture and operating constraints for `illumination`.

## Architecture

Illumination is a single macOS menu bar app. There is no privileged daemon or helper service in the main runtime path.

High-value code areas:

- `Illumination/IlluminationApp.swift`
  - app entry and menu bar wiring
- `Illumination/MenuBarUI.swift`
  - menu bar label and primary menu composition
- `Illumination/IlluminationViewModel.swift`
  - runtime state coordination for UI and controller state
- `Illumination/Brightness.swift`
  - brightness control and EDR behavior
- `Illumination/ALSManager.swift`
  - ambient-light ingestion and policy decisions
- `Illumination/Settings.swift`
  - persisted user settings
- `Illumination/HDRAppList.swift`, `Illumination/AppPolicy.swift`
  - frontmost-app allow and deny policy
- `Illumination/TileFeature.swift`, `Illumination/HDRTile.swift`
  - HDR tile behavior

## Product Model

Durable user-facing capabilities:

- menu bar brightness control
- ambient-light-driven EDR policy
- profile-based ALS tuning
- app-scope policy gates
- optional Run at Login support
- debug ALS trace capture and replay
- experimental HDR detector and ducking paths

## Non-Negotiable Runtime Rules

- built-in displays are the supported target in the current product model
- the app should continue to coexist with macOS auto-brightness instead of replacing it wholesale
- app denylist policy is authoritative when scope is app-limited
- experimental HDR detection must remain non-authoritative relative to the main policy path
- Screen Recording permission should not be required for the normal product path

Current precedence model:

1. app policy deny
2. master and mode state
3. experimental HDR detector adjustments

## ALS and EDR Notes

- lux output is intentionally capped at `120000`
- ALS constants are split conceptually into:
  - decode and sentinel protocol constants
  - ALS hardware profile constants
  - EDR policy profile constants
- current defaults are the MBP16L23-oriented profiles exposed in Debug

The fuller methodology lives in `assets/Algorithm.pdf`.

## Build and Tooling

Prerequisites:

- macOS
- Xcode
- Xcode command line tools
- XcodeGen
- SwiftLint for lint and verify paths

Primary commands:

- `make build`
- `make test`
- `make lint`
- `make verify`
- `make xcodegen-check`

## Generated File Policy

Treat the Xcode project as generated from `project.yml`.

Sources of truth:

- `project.yml`
- `scripts/xcodegen-check.sh`

Expected generated artifact:

- `Illumination.xcodeproj`

If project structure changes, regenerate rather than hand-editing the project opportunistically.

## Release Shape

- semver tags are cut from `master`
- release notes belong in git hosting releases and tags, not an in-repo changelog
