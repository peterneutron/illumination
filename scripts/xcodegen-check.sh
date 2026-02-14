#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="${SCRIPT_DIR}/.."
SPEC_FILE="${PROJECT_ROOT}/project.yml"
PROJECT_PATH="${PROJECT_ROOT}/Illumination.xcodeproj"
PBXPROJ_PATH="${PROJECT_PATH}/project.pbxproj"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found in PATH" >&2
  exit 1
fi

if [[ ! -f "$SPEC_FILE" ]]; then
  echo "error: missing spec file: $SPEC_FILE" >&2
  exit 1
fi

if [[ ! -f "$PBXPROJ_PATH" ]]; then
  echo "error: missing generated project file: $PBXPROJ_PATH" >&2
  exit 1
fi

before_hash="$(shasum -a 256 "$PBXPROJ_PATH" | awk '{print $1}')"
xcodegen generate --spec "$SPEC_FILE" --project "$PROJECT_ROOT" >/dev/null
after_hash="$(shasum -a 256 "$PBXPROJ_PATH" | awk '{print $1}')"

if [[ "$before_hash" != "$after_hash" ]]; then
  echo "error: Xcode project is stale. Run: make xcodegen" >&2
  exit 1
fi

echo "✅ Xcode project is in sync with project.yml."
