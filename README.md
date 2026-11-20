# UniFi OS Server in Docker

Run UniFi OS Server with Docker Compose using the published image from
`ghcr.io/qmaden/unifi-os-server-docker`. This project packages the image from
Ubiquiti's installer for Docker, with persistent storage and readable service logs.

## Quick Start

Clone the repository and run the included Compose file on a Linux Docker host.
Set `UOS_SYSTEM_IP` to an address your UniFi devices can reach.

```sh
git clone https://github.com/qmaden/unifi-os-server-docker.git
cd unifi-os-server-docker
UOS_SYSTEM_IP=192.168.1.10 docker compose up -d --pull always
```

Open `https://localhost:11443` on the Docker host. Compose defaults to the fork's
stable `latest` tag and waits for its MongoDB 8.0 sidecar to respond before
starting UniFi. Set `UNIFI_IMAGE` in `.env` to pin an image tag or digest.
Authenticate Docker to GHCR if the package is private.

The workflow checks Ubiquiti for stable releases every six hours. When an image
is available, update an existing deployment with
`docker compose up -d --pull always unifi-os-server`. Keep `UOS_SYSTEM_IP` in
`.env` so Compose uses the same address on future runs.

**Upgrading an existing stack?** Read the
[MongoDB migration instructions](docs/building.md#mongodb-data) before
updating Compose. [PostgreSQL TCP access](docs/building.md#postgresql-tcp-access)
is optional and requires a database password.

## What's inside

![UniFi OS Server services and log output](docs/images/services.png)

The main container runs UniFi Core, UniFi Network, nginx, PostgreSQL, RabbitMQ,
and supporting services under systemd. Arrows to the log forwarder show log
collection; other service connections are omitted for clarity.

MongoDB can run inside the main container or in an optional separate container.
The `MONGO_INTERNAL` environment variable selects the mode: `"false"` (default)
uses external MongoDB, as in the Compose example; `"true"` uses UniFi Network's
bundled MongoDB. For bundled MongoDB, remove the `unifi-os-server-mongodb` service
and its `depends_on` entry.

## Container logs

Several services run inside this image, each with its own log format. The log
forwarder brings their output together with consistent timestamps, service names,
and severity so you can quickly see what is happening.

Human-readable logs are the default. View them with:

```sh
docker logs -f unifi-os-server
```

```text
2026-11-03T07:24:15.277999Z [postgresql] INFO: Started PostgreSQL Cluster 14-main.
2026-11-03T07:24:15.308Z [uos-entrypoint] INFO: Starting systemd init
```

For a log collector, set `UOS_LOG_FORMAT: "json"` in the service's environment
and apply the change with `docker compose up -d`. Each output line is a JSON
record with `timestamp`, `service`, `level`, `message`, and additional context.
Set it back to `"text"` for readable output.

See the [logging reference](docs/logging.md) for JSON fields, collector examples,
filtering, and log-size limits.

## Patched CVEs

UniFi Network starts with `-XX:-UseBASE64Intrinsics` to mitigate
[Java4Shell (CVE-2026-114938)](https://calif.io/java4shell/). This disables
Java's optimized Base64 implementation while retaining normal Base64 support.
See the [Java mitigation notes](docs/building.md#java4shell-mitigation) for
deployment and verification.

For releases that bundle Node 24, the image includes the following runtime patch
on amd64 and arm64. Older releases retain their Node 22 application runtime.

| CVE | Node.js upgrade | Fix | Status |
| --- | --- | --- | --- |
| [CVE-2026-111497 (Node2Shell)](https://nodejs.org/en/blog/release/v24.22.1/) | 24.8.0 → 24.22.1 | [PR #17](https://github.com/unihosted/unifi-os-server-docker/pull/17) | [Issue #19 — completed](https://github.com/unihosted/unifi-os-server-docker/issues/19) |

See the [Node.js security patch notes](docs/building.md#nodejs-security-patch)
for verification and package update caveats.

## About this project

This fork builds on [UniHosted's Docker packaging](https://github.com/unihosted/unifi-os-server-docker).
It packages the image from Ubiquiti's installer for Docker Compose.

For contributors, the [build and maintenance notes](docs/building.md) cover
supported versions, publishing, and the included Node.js security patch. The
[editable service diagram](docs/images/services.excalidraw) can be opened in Excalidraw.

---

This project is not affiliated with, endorsed by, or supported by Ubiquiti Inc.
All trademarks and copyrights belong to their respective owners.
