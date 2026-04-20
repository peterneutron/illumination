# AGENTS: Working Guide for `illumination`

This file is the source of truth for contributors and coding agents working in this repo.

## Scope

- repo: `illumination` only
- goal: ship a stable menu bar brightness controller for compatible macOS displays
- priority order:
  1. safe runtime behavior on real hardware
  2. deterministic policy decisions
  3. maintainable UI and build flow

## Project Layout

- `Illumination/`
  - app source, runtime logic, and settings
- `IlluminationTests/`
  - unit coverage for core logic
- `IlluminationUITests/`
  - UI-level coverage
- `project.yml`
  - Xcode project source of truth
- `scripts/`
  - signing and project verification helpers

## Non-Negotiable Rules

- do not make Screen Recording a normal-path requirement
- preserve the current policy ordering: app denylist before experimental HDR detector behavior
- do not casually retune ALS or EDR constants without documenting the reason and validating the effect
- treat built-in-display-only support as a product boundary unless the work explicitly expands hardware support
- prefer regeneration from `project.yml` over ad hoc project file edits

## Build and Verification

Run from repo root:

- `make xcodegen-check`
- `make lint`
- `make test`
- `make build`
- `make verify`

## Editing Guidance

- UI/menu behavior usually belongs in `Illumination/MenuBarUI.swift` or `Illumination/AdvancedOptionsMenus.swift`
- ALS and brightness policy changes usually belong in `Illumination/ALSManager.swift` and `Illumination/Brightness.swift`
- settings changes should stay centralized in `Illumination/Settings.swift`
- keep debug and experimental features clearly separated from the main product path

## Release Model

- trunk branch: `master`
- releases are tagged from `master`
- keep the repo clean and releasable from trunk rather than maintaining a ceremonial long-lived `dev`
