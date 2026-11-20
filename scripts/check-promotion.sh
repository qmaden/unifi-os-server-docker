#!/usr/bin/env bash
set -euo pipefail

# The workflow serializes publishing across schedules, pushes, and manual runs.
# Read the version label from the amd64 image config. Docker manifest lists do
# not preserve OCI index-level annotations.
if manifest=$(docker buildx imagetools inspect --raw "$IMAGE:latest" 2>&1); then
    digest=$(jq -er '
        [.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")]
        | if length == 1 then .[0].digest else error("expected one amd64 image") end
    ' <<< "$manifest")
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
    published=$(docker buildx imagetools inspect --format '{{json .Image}}' "$IMAGE@$digest" |
        jq -er '.config.Labels["org.opencontainers.image.version"]
            | strings | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))') || {
        echo "The existing latest image lacks a stable version label." >&2
        exit 1
    }
elif [[ "$manifest" == *"manifest unknown"* || "$manifest" == *"$IMAGE:latest: not found"* ||
        "$manifest" == *"ghcr.io/token"*"403 Forbidden"* ]]; then
    # GHCR can deny a repository-scoped pull token before the package exists.
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
