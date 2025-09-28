#!/bin/bash
set -euo pipefail

if ! command -v security >/dev/null 2>&1; then
  echo "error: 'security' command not available; install Xcode command line tools." >&2
  exit 1
fi

identity_lines=()
while IFS= read -r line; do
  identity_lines+=("$line")
done < <(security find-identity -p codesigning -v 2>/dev/null | awk '/^[[:space:]]*[0-9]+\)/ {print}')

if [[ ${#identity_lines[@]} -eq 0 ]]; then
  echo "error: no valid code signing identities found. Install a free Apple Development certificate via Xcode." >&2
  exit 1
fi

identities=()
display_labels=()

for line in "${identity_lines[@]}"; do
  if [[ "$line" == *CSSMERR_* ]]; then
    continue
  fi
  trimmed=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*//')
  line_no_index=${trimmed#*) }
  fingerprint=${line_no_index%% *}
  identity=$(printf '%s' "$line_no_index" | sed -E 's/^[^"]+"(.*)"$/\1/')
  if [[ -z "$identity" ]]; then
    continue
  fi
  display_labels+=("$identity [fingerprint ${fingerprint:0:6}...]")
  identities+=("$identity")
done

if [[ ${#identities[@]} -eq 0 ]]; then
  echo "error: no valid (non-revoked) code signing identities found. Remove revoked certificates in Keychain Access or create a new Apple Development certificate via Xcode." >&2
  exit 1
fi

if [[ ${#identities[@]} -eq 1 ]]; then
  echo "==> Detected single signing identity: ${display_labels[0]}" >&2
  printf '%s' "${identities[0]}"
  exit 0
fi

echo "==> Select a code signing identity:" >&2
for idx in "${!identities[@]}"; do
  human_index=$((idx + 1))
  echo "  ${human_index}) ${display_labels[$idx]}" >&2
done

selection=""
while true; do
  read -r -p "Identity number (1-${#identities[@]}): " selection >&2 || true
  if [[ -z "$selection" ]]; then
    continue
  fi
  if [[ "$selection" =~ ^[0-9]+$ ]]; then
    selected_index=$((selection - 1))
    if (( selected_index >= 0 && selected_index < ${#identities[@]} )); then
      break
    fi
  fi
  echo "Invalid selection. Please choose a number between 1 and ${#identities[@]}." >&2
done

echo "==> Using signing identity: ${display_labels[$selected_index]}" >&2
printf '%s' "${identities[$selected_index]}"
