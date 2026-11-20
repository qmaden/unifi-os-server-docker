# syntax=docker/dockerfile:1

# Self-contained build: downloads the installer, extracts the embedded OCI
# image with binwalk, unpacks it with umoci, and layers the
# entrypoint on top.  No pre-built base image required.

# ---------------------------------------------------------------------------
# Stage 1 – extract the UniFi OS Server rootfs from the installer binary
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS extractor

ARG TARGETARCH
ARG INSTALLER_URL_AMD64="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"
ARG INSTALLER_URL_ARM64="https://fw-download.ubnt.com/data/unifi-os-server/f730-linux-arm64-5.1.42-d2bca8bd-d6fc-4d20-99e5-b78235843c2f.42-arm64"

ARG INSTALLER_SHA256_AMD64="f6111e9396a42c74016f5dde9b01fbef486a6fe69efe137935e6e38b7c22f94d"
ARG INSTALLER_SHA256_ARM64="8e29bd50cde8f781ace4b85599256ef62c02723bdc751044d4db90a087fb5207"

RUN apt-get update && apt-get install -y --no-install-recommends \
        binwalk jq p7zip-full curl ca-certificates xz-utils umoci \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN /bin/bash <<'EXTRACT'
set -euo pipefail
case "$TARGETARCH" in
    amd64) url="$INSTALLER_URL_AMD64"; checksum="$INSTALLER_SHA256_AMD64" ;;
    arm64) url="$INSTALLER_URL_ARM64"; checksum="$INSTALLER_SHA256_ARM64" ;;
    *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac
[[ "$checksum" =~ ^[[:xdigit:]]{64}$ ]]
curl --proto '=https' --proto-redir '=https' -fL --retry 5 --retry-delay 2 -o installer.bin "$url"
printf '%s  installer.bin\n' "$checksum" | sha256sum -c -
mkdir oci
if python3 -c 'import zipfile, sys; sys.exit(not zipfile.is_zipfile("installer.bin"))'; then
    # Current installers append a ZIP archive to the executable. Stream the
    # embedded tar to avoid storing multiple copies of the same image.
    python3 -c '
import shutil
import sys
import zipfile
with zipfile.ZipFile("installer.bin") as installer, installer.open("image.tar") as image:
    shutil.copyfileobj(image, sys.stdout.buffer)
' | tar xf - -C oci/
    rm installer.bin
else
    binwalk --run-as=root -e installer.bin
    image_tar=$(find /build -type f -name 'image.tar' -print -quit)
    [ -n "$image_tar" ] || { echo "image.tar not found after extraction" >&2; exit 1; }
    tar xf "$image_tar" -C oci/
    rm -rf installer.bin _installer.bin.extracted
fi

# Podman archives can use Docker v2 media types in an OCI layout. Normalize
# the descriptors for umoci, keeping the original config and layer blobs.
digest=$(jq -er '
    if (.manifests | length) == 1 then
        .manifests[0].digest | select(test("^sha256:[a-f0-9]{64}$"))
    else error("expected one embedded image manifest")
    end
' oci/index.json)
jq '
    .mediaType = "application/vnd.oci.image.manifest.v1+json"
    | .config.mediaType = "application/vnd.oci.image.config.v1+json"
    | .layers[].mediaType |= (
        if . == "application/vnd.docker.image.rootfs.diff.tar.gzip" then
            "application/vnd.oci.image.layer.v1.tar+gzip"
        elif . == "application/vnd.docker.image.rootfs.diff.tar" then
            "application/vnd.oci.image.layer.v1.tar"
        else .
        end
    )
' "oci/blobs/sha256/${digest#sha256:}" > manifest.json
normalized_digest=$(sha256sum manifest.json | cut -d' ' -f1)
manifest_size=$(wc -c < manifest.json)
mv manifest.json "oci/blobs/sha256/$normalized_digest"
jq --arg digest "sha256:$normalized_digest" --argjson size "$manifest_size" '
    .manifests[0] |= (
        .mediaType = "application/vnd.oci.image.manifest.v1+json"
        | .digest = $digest
        | .size = $size
        | .annotations["org.opencontainers.image.ref.name"] = "uosserver"
    )
' oci/index.json > oci/index.tmp
mv oci/index.tmp oci/index.json
umoci unpack --image oci:uosserver bundle
mv bundle/rootfs /rootfs
rm -rf /build/*
EXTRACT

# Temporary Node2Shell (CVE-2026-111497) fix until Ubiquiti updates node24.
# Replace the executable used by systemd, preserving Node 24's native addon ABI.
# SHA-256 values are pinned from https://nodejs.org/dist/v24.22.1/SHASUMS256.txt.
RUN /bin/bash <<'PATCH_NODE'
set -euo pipefail

VERSION=24.22.1
case "$TARGETARCH" in
    amd64)
        NODE_ARCH=x64
        SHA256=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6
        ;;
    arm64)
        NODE_ARCH=arm64
        SHA256=dbabf7a1cbf947e6059ffad2c27b80041db97dea1e553b62afdee7f13fca336e
        ;;
    *) echo "Unsupported Node.js architecture: $TARGETARCH" >&2; exit 1 ;;
esac

# Older UOS releases (including 4.3.6) use node22. Install node24 for the
# log forwarder without replacing those application runtimes. If node24 is
# already bundled, retain the patch's runtime layout and ABI checks.
test ! -L /rootfs/usr/bin/node24
OLD_ABI=""
if [ -e /rootfs/usr/bin/node24 ]; then
    test -f /rootfs/usr/bin/node24
    OLD_VERSION=$(chroot /rootfs /usr/bin/node24 -p 'process.versions.node')
    test "${OLD_VERSION%%.*}" = 24
    # Retain a newer vendor binary instead of downgrading a future release.
    if dpkg --compare-versions "$OLD_VERSION" ge "$VERSION"; then
        echo "Keeping bundled Node.js $OLD_VERSION"
        VERSION="$OLD_VERSION"
        NODE_ARCH=""
    fi
    OLD_ABI=$(chroot /rootfs /usr/bin/node24 -p 'process.versions.modules')
fi

if [ -n "$NODE_ARCH" ]; then
    ARCHIVE="node-v${VERSION}-linux-${NODE_ARCH}.tar.xz"
    curl -fL --retry 5 --retry-delay 2 -o "$ARCHIVE" "https://nodejs.org/dist/v${VERSION}/${ARCHIVE}"
    echo "$SHA256  $ARCHIVE" | sha256sum -c -
    mkdir -p /build/node-patch
    tar -xJf "$ARCHIVE" -C /build/node-patch --strip-components=1 \
        "node-v${VERSION}-linux-${NODE_ARCH}/bin/node" \
        "node-v${VERSION}-linux-${NODE_ARCH}/LICENSE"
    install -m 0755 /build/node-patch/bin/node /rootfs/usr/bin/node24
    install -Dm 0644 /build/node-patch/LICENSE /rootfs/usr/share/doc/node24/LICENSE
    rm -rf /build/node-patch "$ARCHIVE"
fi

test "$(chroot /rootfs /usr/bin/node24 --version)" = "v${VERSION}"
if [ -n "$OLD_ABI" ]; then
    test "$(chroot /rootfs /usr/bin/node24 -p 'process.versions.modules')" = "$OLD_ABI"
fi
chroot /rootfs /usr/bin/node24 --openssl-legacy-provider -e '
    const assert = require("node:assert/strict");
    const zlib = require("node:zlib");
    const input = Buffer.from("UniFi Node.js runtime smoke test");
    assert.deepEqual(zlib.brotliDecompressSync(zlib.brotliCompressSync(input)), input);
'
PATCH_NODE

# Temporary Java4Shell (CVE-2026-114938) mitigation for UniFi Network.
# Patch the actual systemd command so existing UNIFI_JVM_OPTS remain intact.
# Fail closed if a future installer changes the service's Java invocation.
RUN /bin/bash <<'PATCH_JAVA'
set -euo pipefail
SERVICE=/rootfs/lib/systemd/system/unifi.service
grep -q '^ExecStart=/usr/bin/java ' "$SERVICE"
sed -i 's|^ExecStart=/usr/bin/java |ExecStart=/usr/bin/java -XX:-UseBASE64Intrinsics |' "$SERVICE"
grep -q '^ExecStart=/usr/bin/java -XX:-UseBASE64Intrinsics ' "$SERVICE"
PATCH_JAVA

COPY uos-entrypoint.sh /rootfs/root/uos-entrypoint.sh
COPY uos-logs.cjs /rootfs/root/uos-logs.cjs
RUN chmod +x /rootfs/root/uos-entrypoint.sh

# ---------------------------------------------------------------------------
# Stage 2 – final image from the extracted rootfs
# ---------------------------------------------------------------------------
FROM scratch

COPY --from=extractor /rootfs /

ARG UOS_SERVER_VERSION="5.1.42"
ARG UOS_SOURCE="https://github.com/qmaden/unifi-os-server-docker"
LABEL org.opencontainers.image.version="${UOS_SERVER_VERSION}" \
      org.opencontainers.image.source="${UOS_SOURCE}"

ENV UOS_SERVER_VERSION="${UOS_SERVER_VERSION}" \
    APP_VERSION="${UOS_SERVER_VERSION}" \
    APP_MODEL="UOSSERVER" \
    PRODUCT_NAME="UniFi OS Server"

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/root/uos-entrypoint.sh"]
