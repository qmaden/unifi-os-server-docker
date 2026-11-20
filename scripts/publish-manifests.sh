#!/usr/bin/env bash
set -euo pipefail

manifests=$(jq -es 'if length > 0 then . else error("missing image digests") end' "$1"/*.json)
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
    version=$(jq -er '.[0].version' <<< "$entries")
    annotation="index:org.opencontainers.image.version=$version"
    docker buildx imagetools create --annotation "$annotation" -t "$IMAGE:$tag" "${sources[@]}"
    if [[ -n "$LATEST" && "$tag" == "$LATEST" ]]; then
        jq -e 'map(.arch) | sort == ["amd64", "arm64"]' >/dev/null <<< "$entries"
        docker buildx imagetools create --annotation "$annotation" -t "$IMAGE:latest" "${sources[@]}"
    fi
    printf '%s\n' "- \`$IMAGE:$tag\`" >> "$GITHUB_STEP_SUMMARY"
done < <(jq -r 'map(.tag) | unique[]' <<< "$manifests")
