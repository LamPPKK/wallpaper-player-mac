#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 0 ]; then
  printf '%s\n' "usage: $0 < homebrew-info.json" >&2
  exit 64
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "Required build tool is missing: jq" >&2
  exit 1
fi

records="$(jq -er '
  if (.formulae | length) < 1 then error("empty renderer dependency closure") else . end
  | .formulae[]
  | if (.installed | length) != 1 then error("expected exactly one installed keg") else . end
  | [
      "formula",
      (.full_name | sub("^homebrew/core/"; "")),
      .installed[0].version,
      (.urls.stable.checksum // "-")
    ]
  | @tsv
' | LC_ALL=C sort)"

if ! printf '%s\n' "$records" | awk -F '\t' '
    NF != 4 || $1 != "formula" { exit 1 }
    $2 !~ /^[a-z0-9][a-z0-9@+_.-]*$/ { exit 1 }
    $3 !~ /^[0-9A-Za-z][0-9A-Za-z._+-]*$/ { exit 1 }
    $4 != "-" && $4 !~ /^[0-9a-f]{64}$/ { exit 1 }
    seen[$2]++ { exit 1 }
    END { if (NR < 1) exit 1 }
  '; then
  printf '%s\n' "Renderer formula lock records are malformed or non-canonical." >&2
  exit 1
fi

printf '%s\n' "$records"
