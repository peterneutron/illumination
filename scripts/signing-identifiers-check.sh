#!/usr/bin/env bash
set -euo pipefail

known_id='DB998TJ36[H]'
team_chars='[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]'
contextual_patterns=(
  "(DEVELOPMENT_TEAM|DevelopmentTeam)[[:space:]]*[:=][[:space:]]*\"?$team_chars\"?"
  "com\\.apple\\.developer\\.team-identifier[^A-Z0-9]{0,32}$team_chars"
  "TeamIdentifier[^A-Z0-9]{0,32}$team_chars"
  "TeamIdentifierPrefix[^A-Z0-9]{0,32}$team_chars"
  "ApplicationIdentifierPrefix[^A-Z0-9]{0,32}$team_chars"
  "Apple (Development|Distribution):.*\\($team_chars\\)"
)
contextual_id="$(IFS='|'; echo "${contextual_patterns[*]}")"

if git grep -n -I -E "$known_id|$contextual_id" -- .; then
  echo "error: tracked Apple developer team identifier found; keep signing IDs in ignored local configuration" >&2
  exit 1
fi

echo "Tracked signing configuration contains no literal Apple team identifiers."
