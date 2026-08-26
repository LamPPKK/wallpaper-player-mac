#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -ne 1 ]; then
  printf '%s\n' "usage: $0 /path/to/dependencies.lock.tsv" >&2
  exit 64
fi

be_require_tools brew git jq sort awk mktemp mv dirname basename rm uname shasum

OUTPUT="$(be_resolve_new_output "$1" "renderer dependency lock")"
OUTPUT_PARENT="$(dirname "$OUTPUT")"
STAGING="$(mktemp "$OUTPUT_PARENT/.background-engine-renderer-lock.XXXXXX")"
cleanup() { [ ! -f "$STAGING" ] || rm -f "$STAGING"; }
trap cleanup EXIT

BREW_VERSION="6.0.19"
BREW_REF="0942cac2eda7648d4857f4e5da60f1de303b6818"
CORE_REF="229d435d9fc7d166b417e94ce66db01d6b34cf97"
case "$(uname -m)" in
  arm64)
    RECEIPT_ARCH="arm64"
    DEPS_ARCH="arm"
    BOTTLE_TAG="arm64_sonoma"
    ;;
  x86_64)
    RECEIPT_ARCH="x86_64"
    DEPS_ARCH="intel"
    BOTTLE_TAG="sonoma"
    ;;
  *)
    printf '%s\n' "Renderer dependencies are unsupported on this architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
if { [ "${GITHUB_ACTIONS:-}" != "true" ] || [ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]; } \
    && [ "${BACKGROUND_ENGINE_ALLOW_HOMEBREW_MUTATION:-}" != "1" ]; then
  printf '%s\n' \
    "Refusing to replace Homebrew formulae outside a GitHub-hosted runner. Set BACKGROUND_ENGINE_ALLOW_HOMEBREW_MUTATION=1 to opt in." >&2
  exit 1
fi
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ASK=1
unset HOMEBREW_NO_INSTALL_UPGRADE HOMEBREW_BUNDLE_NO_UPGRADE || true

BREW_REPOSITORY="$(brew --repository)"
git -C "$BREW_REPOSITORY" fetch --force --depth=1 origin \
  "refs/tags/$BREW_VERSION:refs/tags/$BREW_VERSION"
if [ "$(git -C "$BREW_REPOSITORY" rev-parse "refs/tags/$BREW_VERSION^{commit}")" != "$BREW_REF" ]; then
  printf '%s\n' "Homebrew tag $BREW_VERSION does not resolve to the pinned commit." >&2
  exit 1
fi
be_checkout_pinned_git_commit "$BREW_REPOSITORY" "$BREW_REF" "Homebrew/brew"
if [ "$(git -C "$BREW_REPOSITORY" rev-parse HEAD)" != "$BREW_REF" ]; then
  printf '%s\n' "Homebrew/brew did not resolve to the pinned renderer dependency version." >&2
  exit 1
fi
if [ "$(brew --version | awk 'NR == 1 { print $2; exit }')" != "$BREW_VERSION" ]; then
  printf '%s\n' "Pinned Homebrew/brew did not report version $BREW_VERSION." >&2
  exit 1
fi

brew tap --force homebrew/core
CORE_REPOSITORY="$(brew --repository homebrew/core)"
git -C "$CORE_REPOSITORY" fetch --force --depth=1 origin "$CORE_REF"
be_checkout_pinned_git_commit "$CORE_REPOSITORY" "$CORE_REF" "homebrew/core"
if [ "$(git -C "$CORE_REPOSITORY" rev-parse HEAD)" != "$CORE_REF" ]; then
  printf '%s\n' "Homebrew core did not resolve to the pinned renderer dependency snapshot." >&2
  exit 1
fi
if ! brew info --json=v2 homebrew/core/openssl@3 >/dev/null; then
  printf '%s\n' "Pinned Homebrew cannot parse the renderer dependency formula DSL." >&2
  exit 1
fi

DIRECT=(
  cmake
  pkgconf
  lz4
  sdl2-compat
  ffmpeg
  glfw
  glew
  glm
  mpv
  freetype
  dylibbundler
)
QUALIFIED_DIRECT=()
for formula in "${DIRECT[@]}"; do
  QUALIFIED_DIRECT+=("homebrew/core/$formula")
done
ALL=()
while IFS= read -r formula; do
  [ -z "$formula" ] || ALL+=("$formula")
done < <(
  {
    brew deps --formula --union --topological \
      --os=sonoma --arch="$DEPS_ARCH" "${QUALIFIED_DIRECT[@]}"
    printf '%s\n' "${DIRECT[@]}"
  } | awk '{ sub(/^homebrew\/core\//, "") } NF && !seen[$0]++'
)
if [ "${#ALL[@]}" -eq 0 ]; then
  printf '%s\n' "Pinned renderer dependency closure is empty." >&2
  exit 1
fi
QUALIFIED_ALL=()
for formula in "${ALL[@]}"; do
  QUALIFIED_ALL+=("homebrew/core/$formula")
done

# GitHub's arm64 and Intel runner images are updated on different schedules.
# Fetch the exact Sonoma bottle for every formula before mutating the ephemeral
# CI runner. Installing a formula name with --force-bottle would still select a
# Sequoia bottle on macos-15 and could raise the bundled runtime's minimum OS.
BOTTLES=()
EXPECTED_VERSIONS=()
EXPECTED_STABLE_VERSIONS=()
for formula in "${ALL[@]}"; do
  qualified_formula="homebrew/core/$formula"
  metadata="$(brew info --json=v2 "$qualified_formula")"
  stable_version="$(printf '%s\n' "$metadata" | jq -er '.formulae[0].versions.stable')"
  version="$(printf '%s\n' "$metadata" | jq -er '
    .formulae[0]
    | .versions.stable + (if .revision > 0 then "_" + (.revision | tostring) else "" end)
  ')"
  bottle_record="$(printf '%s\n' "$metadata" | jq -er --arg tag "$BOTTLE_TAG" '
    .formulae[0].bottle.stable.files
    | if has($tag) then [$tag, .[$tag].sha256]
      elif has("all") then ["all", .all.sha256]
      else error("missing requested Sonoma bottle")
      end
    | @tsv
  ')"
  selected_tag="${bottle_record%%$'\t'*}"
  expected_sha="${bottle_record#*$'\t'}"
  if ! printf '%s\n' "$expected_sha" | /usr/bin/grep -Eq '^[[:xdigit:]]{64}$'; then
    printf '%s\n' "Pinned Sonoma bottle has an invalid checksum: $qualified_formula" >&2
    exit 1
  fi
  brew fetch --force --retry --formula --bottle-tag "$BOTTLE_TAG" "$qualified_formula"
  bottle="$(brew --cache --formula --bottle-tag "$BOTTLE_TAG" "$qualified_formula")"
  if [ ! -f "$bottle" ]; then
    printf '%s\n' "Pinned Sonoma bottle is missing for renderer dependency: $formula" >&2
    exit 1
  fi
  if ! printf '%s\n' "$(basename "$bottle")" \
      | /usr/bin/grep -Eq "(^|[.])${selected_tag}([.]|$)"; then
    printf '%s\n' "Homebrew selected the wrong renderer bottle tag: $formula -> $bottle" >&2
    exit 1
  fi
  actual_sha="$(shasum -a 256 "$bottle" | awk '{ print $1 }')"
  if [ "$actual_sha" != "$expected_sha" ]; then
    printf '%s\n' "Renderer bottle checksum mismatch: $formula" >&2
    exit 1
  fi
  BOTTLES+=("$bottle")
  EXPECTED_VERSIONS+=("$version")
  EXPECTED_STABLE_VERSIONS+=("$stable_version")
done

# All downloads and checksum verification completed above. Replace each keg in
# topological order so dependency resolution sees the pinned Sonoma kegs that
# were already installed, and a newer preinstalled runner keg cannot survive in
# the renderer closure. This path is deliberately GitHub-hosted-only unless a
# local developer explicitly opts in above.
#
# Homebrew 6 refuses package paths by default. Developer mode is the documented
# opt-in that lets the pinned Homebrew process the exact, checksum-verified
# bottle paths above instead of interpreting their cache basenames as formulae.
unset HOMEBREW_FORBID_PACKAGES_FROM_PATHS || true
export HOMEBREW_DEVELOPER=1
for index in "${!ALL[@]}"; do
  formula="${ALL[$index]}"
  bottle="${BOTTLES[$index]}"
  installed_count="$(be_homebrew_installed_keg_count "$formula")"
  case "$installed_count" in
    0)
      brew install --no-ask --formula "$bottle"
      ;;
    1)
      # Homebrew's reinstall path temporarily backs up the old keg. Formulae
      # with post-install steps (notably ca-certificates) can still resolve the
      # now-missing old prefix while the replacement bottle is being poured.
      # The complete closure was fetched and verified before this loop, so
      # remove the single stale runner keg first and perform a clean pour.
      brew uninstall --force --ignore-dependencies --formula "homebrew/core/$formula"
      brew install --no-ask --formula "$bottle"
      ;;
    *)
      if [ "${GITHUB_ACTIONS:-}" != "true" ] \
          || [ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]; then
        printf '%s\n' \
          "Refusing to remove multiple installed Homebrew kegs outside a GitHub-hosted runner: $formula" >&2
        exit 1
      fi
      brew uninstall --force --ignore-dependencies --formula "homebrew/core/$formula"
      brew install --no-ask --formula "$bottle"
      ;;
  esac
done

if [ "$(git -C "$CORE_REPOSITORY" rev-parse HEAD)" != "$CORE_REF" ]; then
  printf '%s\n' "Homebrew core changed while installing renderer dependencies." >&2
  exit 1
fi
if [ "$(git -C "$BREW_REPOSITORY" rev-parse HEAD)" != "$BREW_REF" ]; then
  printf '%s\n' "Homebrew/brew changed while installing renderer dependencies." >&2
  exit 1
fi

assert_linked() {
  local formula="$1"
  local expected="$2"
  local actual
  actual="$(brew info --json=v2 "homebrew/core/$formula" | jq -er '.formulae[0].linked_keg')"
  if [ "$actual" != "$expected" ]; then
    printf '%s\n' "Unexpected $formula version: $actual (expected $expected)" >&2
    return 1
  fi
}

for index in "${!ALL[@]}"; do
  formula="${ALL[$index]}"
  expected_version="${EXPECTED_VERSIONS[$index]}"
  expected_stable_version="${EXPECTED_STABLE_VERSIONS[$index]}"
  # `brew info --installed <name>` lists every installed formula in Homebrew
  # 6.0.19 instead of filtering to <name>. Query the pinned qualified formula
  # directly so formulae[0] is deterministic and still includes install state.
  installation="$(brew info --json=v2 "homebrew/core/$formula")"
  if ! printf '%s\n' "$installation" \
      | be_homebrew_installation_matches "$expected_version"; then
    printf '%s\n' "Renderer dependency did not install exactly the pinned keg: $formula $expected_version" >&2
    exit 1
  fi
  receipt="$(brew --prefix "$formula")/INSTALL_RECEIPT.json"
  # For an explicit local bottle, Homebrew records the pour host in
  # built_on.os_version. The metadata-selected filename tag and SHA-256 checked
  # before installation are therefore the authoritative Sonoma provenance.
  if [ ! -f "$receipt" ] || ! be_homebrew_receipt_matches \
      "$RECEIPT_ARCH" "$expected_stable_version" "$CORE_REF" < "$receipt"; then
    printf '%s\n' "Renderer dependency receipt is not from the pinned bottle: $formula" >&2
    exit 1
  fi
done

assert_linked cmake 4.4.2
assert_linked pkgconf 3.0.5
assert_linked lz4 1.10.0
assert_linked sdl2-compat 2.32.70
assert_linked sdl3 3.4.14
assert_linked ffmpeg 9.0.1
assert_linked glfw 3.5.1
assert_linked glew 2.3.1
assert_linked glm 1.0.3
assert_linked mpv 0.41.0_8
assert_linked freetype 2.14.3
assert_linked dylibbundler 1.0.5
assert_linked libbluray 1.5.0
assert_linked luajit 2.1.1787165859
assert_linked vulkan-loader 1.4.357.0

brew missing "${DIRECT[@]}"
for formula in ffmpeg mpv glfw sdl2-compat sdl3 lz4 freetype; do
  brew linkage --test "$formula"
done

{
  printf 'homebrew-brew\t%s\n' "$BREW_REF"
  printf 'homebrew-core\t%s\n' "$CORE_REF"
  printf 'deployment-target\tmacos-14\n'
  brew info --json=v2 "${QUALIFIED_ALL[@]}" \
    | jq -r '
        .formulae[]
        | [
            "formula",
            .full_name,
            (.linked_keg // ""),
            (.urls.stable.checksum // "")
          ]
        | @tsv
      ' \
    | LC_ALL=C sort
} > "$STAGING"

if [ ! -s "$STAGING" ]; then
  printf '%s\n' "Renderer dependency lock is empty." >&2
  exit 1
fi
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  printf '%s\n' "Refusing to overwrite existing renderer dependency lock: $OUTPUT" >&2
  exit 1
fi
mv "$STAGING" "$OUTPUT"
trap - EXIT
printf '%s\n' "$OUTPUT"
