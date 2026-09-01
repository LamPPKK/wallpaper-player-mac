#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: $0 formula-name < homebrew-info.json" >&2
  exit 64
fi

FORMULA="$1"
if ! printf '%s\n' "$FORMULA" \
    | /usr/bin/grep -Eq '^[a-z0-9][a-z0-9@+_.-]*$'; then
  printf '%s\n' "Unsafe renderer dependency formula name: $FORMULA" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "Required build tool is missing: jq" >&2
  exit 1
fi

records="$(jq -er --arg formula "$FORMULA" '
  def selected($preferred):
    if has($preferred) then [$preferred, .[$preferred].sha256]
    elif has("all") then ["all", .all.sha256]
    else error("missing required Sonoma bottle")
    end;
  .formulae as $formulae
  | if ($formulae | length) != 1 then error("expected exactly one formula") else . end
  | .formulae[0] as $metadata
  | ($metadata.full_name | sub("^homebrew/core/"; "")) as $actual_name
  | if $actual_name != $formula then error("formula metadata name mismatch") else . end
  | $metadata.bottle.stable.files
  | [
      (["bottle", $formula, "arm64"] + selected("arm64_sonoma")),
      (["bottle", $formula, "x86_64"] + selected("sonoma"))
    ]
  | .[]
  | @tsv
')"

if ! printf '%s\n' "$records" | awk -F '\t' '
    NF != 5 || $1 != "bottle" { exit 1 }
    $2 !~ /^[a-z0-9][a-z0-9@+_.-]*$/ { exit 1 }
    $3 == "arm64" && $4 != "arm64_sonoma" && $4 != "all" { exit 1 }
    $3 == "x86_64" && $4 != "sonoma" && $4 != "all" { exit 1 }
    $3 != "arm64" && $3 != "x86_64" { exit 1 }
    $5 !~ /^[0-9a-f]{64}$/ { exit 1 }
    END { if (NR != 2) exit 1 }
  '; then
  printf '%s\n' "Pinned Sonoma bottle metadata is malformed for: $FORMULA" >&2
  exit 1
fi

printf '%s\n' "$records"
