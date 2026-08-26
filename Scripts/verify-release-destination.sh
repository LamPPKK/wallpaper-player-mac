#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime-script-common.sh
source "$ROOT/Scripts/runtime-script-common.sh"

if [ "$#" -ne 3 ]; then
  printf '%s\n' "Usage: $0 <event-name> <release-tag> <owner/repository>" >&2
  exit 64
fi

EVENT_NAME="$1"
RELEASE_TAG="$2"
REPOSITORY="$3"

be_require_tools git gh

case "$EVENT_NAME" in
  push|workflow_dispatch) ;;
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
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf '%s\n' "Refusing invalid GitHub repository: $REPOSITORY" >&2
  exit 1
fi

set +e
git ls-remote --exit-code --refs origin "refs/tags/$RELEASE_TAG" >/dev/null 2>&1
REMOTE_TAG_STATUS="$?"
set -e
case "$REMOTE_TAG_STATUS" in
  0) REMOTE_TAG_EXISTS="1" ;;
  2) REMOTE_TAG_EXISTS="0" ;;
  *)
    printf '%s\n' "Unable to verify whether release tag exists: $RELEASE_TAG" >&2
    exit 1
    ;;
esac

if [ "$EVENT_NAME" = "workflow_dispatch" ] && [ "$REMOTE_TAG_EXISTS" = "1" ]; then
  printf '%s\n' "Release tag already exists; refusing to move or overwrite it: $RELEASE_TAG" >&2
  exit 1
fi
if [ "$EVENT_NAME" = "push" ] && [ "$REMOTE_TAG_EXISTS" = "0" ]; then
  printf '%s\n' "Pushed release tag is missing from the remote: $RELEASE_TAG" >&2
  exit 1
fi

OWNER="${REPOSITORY%%/*}"
REPOSITORY_NAME="${REPOSITORY#*/}"
RELEASE_ID="$(
  gh api graphql \
    --raw-field query='query($owner: String!, $name: String!, $tag: String!) { repository(owner: $owner, name: $name) { release(tagName: $tag) { id } } }' \
    --raw-field owner="$OWNER" \
    --raw-field name="$REPOSITORY_NAME" \
    --raw-field tag="$RELEASE_TAG" \
    --jq '.data.repository.release.id // empty'
)"
if [ -n "$RELEASE_ID" ]; then
  printf '%s\n' "GitHub Release already exists; refusing to update it implicitly: $RELEASE_TAG" >&2
  exit 1
fi

if [ "$EVENT_NAME" = "push" ]; then
  printf '%s\n' "Verified pushed tag has no existing GitHub Release: $RELEASE_TAG"
else
  printf '%s\n' "Verified release destination is unused: $RELEASE_TAG"
fi
