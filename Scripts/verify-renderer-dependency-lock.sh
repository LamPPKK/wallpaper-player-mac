#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: $0 /path/to/dependencies.lock.tsv" >&2
  exit 64
fi

LOCK="$1"
if [ "${LOCK#/}" = "$LOCK" ] || [ ! -s "$LOCK" ] || [ -L "$LOCK" ]; then
  printf '%s\n' "Renderer dependency lock is missing or unsafe: $LOCK" >&2
  exit 1
fi

BREW_REF="0942cac2eda7648d4857f4e5da60f1de303b6818"
CORE_REF="229d435d9fc7d166b417e94ce66db01d6b34cf97"
if ! awk -F '\t' -v brew_ref="$BREW_REF" -v core_ref="$CORE_REF" '
    NR == 1 {
      if (NF != 2 || $1 != "homebrew-brew" || $2 != brew_ref) exit 1
      next
    }
    NR == 2 {
      if (NF != 2 || $1 != "homebrew-core" || $2 != core_ref) exit 1
      next
    }
    NR == 3 {
      if (NF != 2 || $1 != "deployment-target" || $2 != "macos-14") exit 1
      next
    }
    $1 == "formula" {
      if (phase == "bottle" || NF != 4) exit 1
      if ($2 !~ /^[a-z0-9][a-z0-9@+_.-]*$/) exit 1
      if ($3 !~ /^[0-9A-Za-z][0-9A-Za-z._+-]*$/) exit 1
      if ($4 != "-" && $4 !~ /^[0-9a-f]{64}$/) exit 1
      if (formula[$2]++ || ($2 <= previous_formula && previous_formula != "")) exit 1
      previous_formula = $2
      formula_count += 1
      next
    }
    $1 == "bottle" {
      phase = "bottle"
      if (NF != 5) exit 1
      if ($2 !~ /^[a-z0-9][a-z0-9@+_.-]*$/) exit 1
      if ($3 == "arm64") {
        if ($4 != "arm64_sonoma" && $4 != "all") exit 1
        arm[$2] += 1
      } else if ($3 == "x86_64") {
        if ($4 != "sonoma" && $4 != "all") exit 1
        intel[$2] += 1
      } else {
        exit 1
      }
      if ($5 !~ /^[0-9a-f]{64}$/) exit 1
      key = $2 "\t" $3
      if (bottle[key]++) exit 1
      if (previous_bottle != "" && key <= previous_bottle) exit 1
      previous_bottle = key
      bottle_count += 1
      next
    }
    { exit 1 }
    END {
      if (NR < 6 || formula_count < 1 || bottle_count != formula_count * 2) exit 1
      for (name in formula) {
        if (arm[name] != 1 || intel[name] != 1) exit 1
      }
      for (name in arm) if (!(name in formula)) exit 1
      for (name in intel) if (!(name in formula)) exit 1
    }
  ' "$LOCK"; then
  printf '%s\n' "Renderer dependency lock is malformed or non-canonical: $LOCK" >&2
  exit 1
fi

printf '%s\n' "Verified renderer dependency lock: $LOCK"
