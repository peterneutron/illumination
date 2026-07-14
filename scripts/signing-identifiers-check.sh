#!/usr/bin/env bash
set -euo pipefail

known_id='DB998TJ36[H]'
contextual_id='(DEVELOPMENT_TEAM|DevelopmentTeam)[[:space:]]*[:=][[:space:]]*"?[A-Z0-9]{10}"?|(com\.apple\.developer\.team-identifier|TeamIdentifier|TeamIdentifierPrefix|ApplicationIdentifierPrefix)[^A-Z0-9]{0,32}[A-Z0-9]{10}|Apple (Development|Distribution):.*\([A-Z0-9]{10}\)'

if git grep -n -I -E "$known_id|$contextual_id" -- .; then
  echo "error: tracked Apple developer team identifier found; keep signing IDs in ignored local configuration" >&2
  exit 1
fi

echo "Tracked signing configuration contains no literal Apple team identifiers."
