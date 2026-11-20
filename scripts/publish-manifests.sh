#!/usr/bin/env bash
set -euo pipefail

manifests=$(jq -es 'if length > 0 then . else error("missing image digests") end' "$1"/*.json)
if [[ -n "$LATEST" ]]; then
    jq -e --arg latest "$LATEST" '
        map(select(.tag == $latest) | .arch) | sort == ["amd64", "arm64"]
    ' >/dev/null <<< "$manifests"
    # Recheck with the package writer's credentials before moving any tags.
    decision=$(mktemp)
    trap 'rm -f "$decision"' EXIT
    CANDIDATE="$LATEST" GITHUB_OUTPUT="$decision" bash "$(dirname "$0")/check-promotion.sh"
    if grep -qx 'build=false' "$decision"; then
        exit 0
    fi
fi
while IFS= read -r tag; do
    entries=$(jq -c --arg tag "$tag" '[.[] | select(.tag == $tag)]' <<< "$manifests")
    sources=()
    while IFS=$'\t' read -r arch digest; do
        [[ "$arch" == amd64 || "$arch" == arm64 ]]
        [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
        source="$IMAGE@$digest"
        docker buildx imagetools create --prefer-index=false -t "$IMAGE:$tag-$arch" "$source"
        sources+=("$source")
    done < <(jq -r '.[] | [.arch, .digest] | @tsv' <<< "$entries")
    docker buildx imagetools create -t "$IMAGE:$tag" "${sources[@]}"
    if [[ -n "$LATEST" && "$tag" == "$LATEST" ]]; then
        docker buildx imagetools inspect --raw "$IMAGE:$tag" |
            jq -e '[.manifests[] | select(.platform.os == "linux") | .platform.architecture]
                | sort == ["amd64", "arm64"]' >/dev/null
        docker buildx imagetools create -t "$IMAGE:latest" "${sources[@]}"
    fi
    printf '%s\n' "- \`$IMAGE:$tag\`" >> "$GITHUB_STEP_SUMMARY"
done < <(jq -r 'map(.tag) | unique[]' <<< "$manifests")
