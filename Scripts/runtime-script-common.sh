#!/usr/bin/env bash

# Shared, side-effect-free helpers for release/runtime scripts. Callers must
# enable their own shell options before sourcing this file.

be_require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf '%s\n' "Required build tool is missing: $tool" >&2
      return 1
    fi
  done
  if [ ! -x /usr/bin/grep ]; then
    printf '%s\n' "Required build tool is missing: /usr/bin/grep" >&2
    return 1
  fi
}

be_resolve_new_output() {
  if [ "$#" -ne 2 ]; then
    printf '%s\n' "be_resolve_new_output requires a path and a description." >&2
    return 64
  fi

  local requested="$1"
  local description="$2"
  case "$requested" in
    ""|"/"|"."|".."|"$HOME"|*/./*|*/../*|*/.|*/..)
      printf '%s\n' "Refusing unsafe $description output: $requested" >&2
      return 1
      ;;
  esac

  local parent_input
  local parent
  local leaf
  local resolved
  parent_input="$(dirname "$requested")"
  leaf="$(basename "$requested")"
  if [ ! -d "$parent_input" ]; then
    printf '%s\n' "$description output parent does not exist: $parent_input" >&2
    return 1
  fi
  parent="$(cd -P "$parent_input" && pwd)"
  resolved="$parent/$leaf"

  case "$resolved" in
    "/"|"$HOME"|"$parent"|"$parent/"|"$parent/."|"$parent/..")
      printf '%s\n' "Refusing unsafe $description output: $requested" >&2
      return 1
      ;;
    "$parent"/*)
      ;;
    *)
      printf '%s\n' "$description output escapes its normalized parent: $requested" >&2
      return 1
      ;;
  esac

  if [ -e "$resolved" ] || [ -L "$resolved" ]; then
    printf '%s\n' "Refusing to overwrite existing $description: $resolved" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}
