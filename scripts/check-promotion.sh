#!/usr/bin/env bash
set -euo pipefail

# The workflow serializes publishing across schedules, pushes, and manual runs.
# The version stored on the published index also prevents stale runs downgrading it.
if manifest=$(docker buildx imagetools inspect --raw "$IMAGE:latest" 2>&1); then
    published=$(jq -er '.annotations["org.opencontainers.image.version"]
        | strings | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<< "$manifest") || {
        echo "The existing latest index lacks a stable version annotation." >&2
        exit 1
    }
elif [[ "$manifest" == *"manifest unknown"* || "$manifest" == *"$IMAGE:latest: not found"* ||
        "$manifest" == *"failed to fetch anonymous token:"*"403 Forbidden"* ]]; then
    # GHCR returns a denied anonymous pull token before the package exists.
    # A job with no write access will still be unable to upload an image.
    published=""
else
    printf '%s\n' "$manifest" >&2
    exit 1
fi

if [[ -n "$published" && "$published" != "$CANDIDATE" &&
      $(printf '%s\n' "$published" "$CANDIDATE" | sort -V | tail -1) == "$published" ]]; then
    echo "Published version $published is newer than $CANDIDATE."
    echo "build=false" >> "$GITHUB_OUTPUT"
elif [[ "$published" == "$CANDIDATE" && "$GITHUB_EVENT_NAME" == schedule ]]; then
    echo "$CANDIDATE is already published."
    echo "build=false" >> "$GITHUB_OUTPUT"
else
    echo "build=true" >> "$GITHUB_OUTPUT"
fi
