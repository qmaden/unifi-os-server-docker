# Building and maintaining the image

[Back to the README](../README.md)

These notes are for contributors and maintainers. To run the published image,
follow the README's Quick Start.

## Build pipeline

The [Dockerfile](../Dockerfile) verifies the official Ubiquiti installer against
its catalog SHA-256, extracts the embedded image, converts the manifest to OCI,
and uses umoci to unpack its layers.

## Automated stable publishing

On the default branch, [GitHub Actions](../.github/workflows/build-image.yml)
polls Ubiquiti's `release` channel every six hours. When both Linux installers
report the same new version, native amd64 and arm64 runners build their images.
Each runner boots the Compose stack with MongoDB 8.0 and checks the UniFi OS
HTTPS endpoint, UniFi Network HTTPS status, and PostgreSQL readiness. The publish
job uses the tested images' digests to create the version and `latest` indexes.
An existing `latest` version is never downgraded. A scheduled run skips a version
already published. A push that changes build files on `main` can rebuild the
current stable version.

Enable the workflow from the fork's Actions tab if GitHub prompts you. GitHub
can disable scheduled workflows in public repositories after 60 days without
repository activity. In that case, re-enable the workflow under Actions. Set the
GHCR package's visibility to public if you want anonymous pulls.

Use **Run workflow** with the default `latest` to publish the current stable
release on demand, or uncheck **Publish the build to GHCR** for a dry run.
An explicit stable version or `all` builds versioned tags only. For a preview,
enter a version and the official installer URL and SHA-256 for each platform
you want to test. Custom installers publish only under `<version>-preview` and
its architecture-specific tags. A Git tag such as `v5.1.42` builds that version.

For a local build of the bundled installer defaults, run
`docker build -t unifi-os-server:local .`. Use `UNIFI_IMAGE=unifi-os-server:local`
with Compose to run it.

## MongoDB data

New deployments use MongoDB 8.0. The Compose sidecar checks the bind mount
before opening it with a different MongoDB major version. Existing installations
using MongoDB 4.4 can keep running against their current data by adding
`MONGO_IMAGE=mongo:4.4` to `.env`. MongoDB 4.4 is end-of-life.

Back up the UniFi configuration and the MongoDB data before migrating, and
verify restore on a separate deployment. For an in-place database migration,
follow the MongoDB upgrade instructions for each supported step from 4.4 to 5.0,
6.0, 7.0, and 8.0, including each step's feature compatibility version changes.
Once the data has been migrated and tested with 8.0, set `MONGO_IMAGE=mongo:8.0`
and `MONGO_ACCEPT_EXISTING_DATA=true` for the first start if the volume has no
8.0 marker. Remove the opt-in after startup. `MONGO_DATA_DIR` selects the bind
mount when restoring to a separate location.

## PostgreSQL TCP access

PostgreSQL listens only on loopback inside the container by default and Compose
publishes no PostgreSQL port. To enable host access, add
`UOS_POSTGRES_TCP: "true"` to the UniFi service environment and
`127.0.0.1:5432:5432` to its ports. Use a PostgreSQL role with a SCRAM password.
Unix socket authentication stays as configured in the bundled image.

## Node.js security patch

For releases that bundle Node 24, the image upgrades an older `/usr/bin/node24` with the
official Node.js **24.22.1** binary on amd64 and arm64 to address
[Node2Shell (CVE-2026-111497)](https://nodejs.org/en/blog/release/v24.22.1/).
Downloads are checked against pinned SHA-256 hashes. The build verifies the
version, preserves the existing Node 24 native addon ABI, and checks Brotli
compression/decompression inside the extracted rootfs. Releases that bundle
Node 22 receive Node 24 for the log forwarder while retaining their application
runtime.

This is a temporary runtime override until Ubiquiti ships a fixed package. The Debian `node24` package metadata still reports Ubiquiti's original version; check the running binary with `docker exec unifi-os-server /usr/bin/node24 --version`. An in-container package update can overwrite the patched binary, so deploy rebuilt images to retain the fix. When updating the patch, change the version and both architecture hashes together in `Dockerfile`.

## Java4Shell mitigation

The build adds `-XX:-UseBASE64Intrinsics` directly to UniFi Network's systemd
`ExecStart` Java command, preserving `UNIFI_JVM_OPTS` and its heap settings.
This mitigates [CVE-2026-114938](https://calif.io/java4shell/) by disabling the
vulnerable optimized Base64 implementation. Normal Base64 processing remains
available, with a possible performance cost. The flag is applied to both
architectures; unlike `-XX:UseAVX=2`, it is not specific to x86.

Deploy a rebuilt image and recreate the container to activate the mitigation;
restarting a container using an old image does not install it. Verify the running
UniFi Java command contains `-XX:-UseBASE64Intrinsics` and that no custom JVM
options re-enable it with `-XX:+UseBASE64Intrinsics`.

This is a workaround, not a patched Java runtime. Remove it only after verifying
that Ubiquiti's bundled Java includes the vendor's fix. Package updates inside a
container may replace the patched service; deploy rebuilt images instead. The
build fails if the expected service command is absent, so installer changes
require review rather than silently dropping the mitigation.
