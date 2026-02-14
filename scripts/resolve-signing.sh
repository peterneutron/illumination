#!/bin/bash
set -euo pipefail

# Resolves signing identity and team with deterministic priority:
# 1) explicit env (SIGNING_IDENTITY / DEVELOPMENT_TEAM)
# 2) automatic identity discovery
# 3) interactive fallback (if TTY and allowed)

require_noninteractive="${REQUIRE_NONINTERACTIVE:-0}"
allow_interactive="${ALLOW_INTERACTIVE:-1}"

derive_team_from_identity() {
  local identity="$1"
  printf '%s\n' "$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p'
}

list_identities() {
  security find-identity -p codesigning -v 2>/dev/null \
    | awk '/^[[:space:]]*[0-9]+\)/ {print}' \
    | awk '!/CSSMERR_/'
}

choose_identity_auto() {
  local requested_team="$1"
  local identity_lines
  identity_lines="$(list_identities || true)"
  if [[ -z "$identity_lines" ]]; then
    return 1
  fi

  local best=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local trimmed line_no_index identity team
    trimmed="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*//')"
    line_no_index="${trimmed#*) }"
    identity="$(printf '%s' "$line_no_index" | sed -E 's/^[^"]+"(.*)"$/\1/')"
    [[ -z "$identity" ]] && continue

    team="$(derive_team_from_identity "$identity")"

    if [[ -n "$requested_team" && "$team" == "$requested_team" ]]; then
      printf '%s\n' "$identity"
      return 0
    fi

    if [[ -z "$best" ]]; then
      best="$identity"
    fi

    if [[ "$identity" == Apple\ Development* ]]; then
      best="$identity"
      if [[ -z "$requested_team" ]]; then
        break
      fi
    fi
  done <<< "$identity_lines"

  if [[ -n "$best" ]]; then
    printf '%s\n' "$best"
    return 0
  fi

  return 1
}

emit_shell_vars() {
  local identity="$1"
  local team="$2"
  printf 'SIGNING_IDENTITY=%q\n' "$identity"
  printf 'DEVELOPMENT_TEAM=%q\n' "$team"
}

identity="${SIGNING_IDENTITY:-}"
team="${DEVELOPMENT_TEAM:-}"

if [[ -n "$identity" && -z "$team" ]]; then
  team="$(derive_team_from_identity "$identity")"
fi

if [[ -z "$identity" ]]; then
  identity="$(choose_identity_auto "$team" || true)"
fi

if [[ -n "$identity" && -z "$team" ]]; then
  team="$(derive_team_from_identity "$identity")"
fi

if [[ -z "$identity" ]]; then
  if [[ "$require_noninteractive" == "1" ]]; then
    echo "error: no signing identity resolved in non-interactive mode; set SIGNING_IDENTITY and DEVELOPMENT_TEAM." >&2
    exit 1
  fi

  if [[ "$allow_interactive" == "1" && -t 0 && -x "$(dirname "$0")/select_signing_identity.sh" ]]; then
    identity="$("$(dirname "$0")/select_signing_identity.sh")"
    team="$(derive_team_from_identity "$identity")"
  fi
fi

if [[ -z "$identity" || -z "$team" ]]; then
  cat >&2 <<ERR
error: unable to resolve signing identity and team.
Set both values explicitly for deterministic builds:
  SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)"
  DEVELOPMENT_TEAM="TEAMID"
ERR
  exit 1
fi

emit_shell_vars "$identity" "$team"
