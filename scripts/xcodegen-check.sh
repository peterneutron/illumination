#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="${SCRIPT_DIR}/.."
SPEC_FILE="${PROJECT_ROOT}/project.yml"
PROJECT_PATH="${PROJECT_ROOT}/Illumination.xcodeproj"
PBXPROJ_PATH="${PROJECT_PATH}/project.pbxproj"
XCODEGEN_SPEC="./project.yml"
XCODEGEN_PROJECT="."

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

normalize_pbxproj() {
  local src="$1"
  local dst="$2"
  sed -E \
    -e 's/objectVersion = [0-9]+;/objectVersion = <normalized>;/g' \
    -e 's/preferredProjectObjectVersion = [0-9]+;/preferredProjectObjectVersion = <normalized>;/g' \
    -e '/compatibilityVersion = "Xcode [^"]+";/d' \
    -e '/productRefGroup = [A-F0-9]+ \/\* Products \*\//d' \
    "$src" >"$dst"
}

before_norm="$(mktemp)"
after_norm="$(mktemp)"
project_backup="$(mktemp -d)"
project_backup_path="${project_backup}/Illumination.xcodeproj"
trap 'rm -f "$before_norm" "$after_norm"; rm -rf "$project_backup"' EXIT

cp -R "$PROJECT_PATH" "$project_backup_path"
normalize_pbxproj "${project_backup_path}/project.pbxproj" "$before_norm"
before_hash="$(shasum -a 256 "$before_norm" | awk '{print $1}')"
(
  cd "$PROJECT_ROOT"
  xcodegen generate --spec "$XCODEGEN_SPEC" --project "$XCODEGEN_PROJECT" >/dev/null
)
normalize_pbxproj "$PBXPROJ_PATH" "$after_norm"
after_hash="$(shasum -a 256 "$after_norm" | awk '{print $1}')"

rm -rf "$PROJECT_PATH"
cp -R "$project_backup_path" "$PROJECT_PATH"

if [[ "$before_hash" != "$after_hash" ]]; then
  echo "error: Xcode project is stale. Run: make xcodegen" >&2
  exit 1
fi

echo "✅ Xcode project is in sync with project.yml."
