#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -ne 7 ]; then
  printf '%s\n' \
    "Usage: $0 <event-name> <ref-type> <ref-name> <tag-created> <dispatch-release-tag> <dispatch-marketing-version> <dispatch-build-number>" >&2
  exit 64
fi

EVENT_NAME="$1"
REF_TYPE="$2"
REF_NAME="$3"
TAG_CREATED="$4"
DISPATCH_RELEASE_TAG="$5"
DISPATCH_MARKETING_VERSION="$6"
DISPATCH_BUILD_NUMBER="$7"
DEFAULT_MARKETING_VERSION="0.2.0-alpha.1"
DEFAULT_BUILD_NUMBER="11"

be_require_tools git

case "$EVENT_NAME" in
  push)
    if [ "$REF_TYPE" != "tag" ]; then
      printf '%s\n' "Release push events must target a tag, not: $REF_TYPE" >&2
      exit 1
    fi
    if [ "$TAG_CREATED" != "true" ]; then
      printf '%s\n' "Refusing release from a moved, deleted, or pre-existing tag push: $REF_NAME" >&2
      exit 1
    fi
    RELEASE_TAG="$REF_NAME"
    MARKETING_VERSION="${RELEASE_TAG#v}"
    BUILD_NUMBER="$DEFAULT_BUILD_NUMBER"
    ;;
  workflow_dispatch)
    RELEASE_TAG="$DISPATCH_RELEASE_TAG"
    MARKETING_VERSION="${DISPATCH_MARKETING_VERSION:-$DEFAULT_MARKETING_VERSION}"
    BUILD_NUMBER="${DISPATCH_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
    ;;
  *)
    printf '%s\n' "Unsupported release event: $EVENT_NAME" >&2
    exit 1
    ;;
esac

if [[ ! "$RELEASE_TAG" =~ ^v[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || ! git check-ref-format "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
  printf '%s\n' "Refusing invalid release tag: $RELEASE_TAG" >&2
  exit 1
fi
if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+([.][0-9]+)*(-[A-Za-z0-9]+([.][A-Za-z0-9]+)*)?$ ]]; then
  printf '%s\n' "Refusing invalid marketing version: $MARKETING_VERSION" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "Refusing invalid build number: $BUILD_NUMBER" >&2
  exit 1
fi

printf 'release_tag=%s\n' "$RELEASE_TAG"
printf 'marketing_version=%s\n' "$MARKETING_VERSION"
printf 'build_number=%s\n' "$BUILD_NUMBER"
