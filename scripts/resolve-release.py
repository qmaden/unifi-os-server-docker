#!/usr/bin/env python3
"""Resolve checksummed UniFi OS Server installers from Ubiquiti's firmware catalog."""

import json
import os
import re
import sys
from urllib.parse import urlencode
from urllib.request import urlopen

API = "https://fw-update.ubnt.com/api"
PLATFORMS = {"amd64": "linux-x64", "arm64": "linux-arm64"}
STABLE_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
IMAGE_TAG = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9][a-zA-Z0-9.-]{0,79})?")
IMAGE_NAME = re.compile(r"[a-z0-9]+(?:[._-][a-z0-9]+)*")
INSTALLER_URL = re.compile(r"https://fw-download\.(?:ubnt|ui)\.com/data/unifi-os-server/[a-zA-Z0-9._-]+")
SHA256 = re.compile(r"[a-fA-F0-9]{64}")


def asset(version, arch, url, sha256, preview=False):
    if not INSTALLER_URL.fullmatch(url) or not SHA256.fullmatch(sha256):
        raise ValueError(f"{version} {arch} needs a Ubiquiti installer URL and SHA-256")
    return {
        "version": version,
        "tag": f"{version}-preview" if preview else version,
        "arch": arch,
        "runner": "ubuntu-24.04-arm" if arch == "arm64" else "ubuntu-24.04",
        "url": url,
        "sha256": sha256.lower(),
    }


def catalog(arch, requested):
    platform = PLATFORMS[arch]
    filters = [
        "eq~~product~~unifi-os-server",
        f"eq~~platform~~{platform}",
        "eq~~channel~~release",
    ]
    if requested not in ("latest", "all"):
        filters.append(f"eq~~version~~v{requested}")
    endpoint = "firmware-latest" if requested == "latest" else "firmware"
    query = urlencode([("filter", value) for value in filters], safe="~")
    with urlopen(f"{API}/{endpoint}?{query}", timeout=30) as response:
        payload = json.load(response)
    entries = payload["_embedded"]["firmware"]
    installers = {}
    for entry in entries:
        version = entry["version"].removeprefix("v")
        if (
            (entry["product"], entry["platform"], entry["channel"])
            != ("unifi-os-server", platform, "release")
            or not STABLE_VERSION.fullmatch(version)
            or (requested not in ("latest", "all") and version != requested)
        ):
            continue
        installer = asset(version, arch, entry["_links"]["data"]["href"], entry["sha256_checksum"])
        if version in installers and installers[version] != installer:
            raise ValueError(f"Multiple installer revisions for {version} {arch}")
        installers[version] = installer
    return installers


def resolve(requested, overrides):
    if overrides:
        if not IMAGE_TAG.fullmatch(requested):
            raise ValueError("Custom installers require an explicit version")
        return "", [asset(requested, arch, url, sha256, preview=True) for arch, url, sha256 in overrides]

    if requested not in ("latest", "all") and not STABLE_VERSION.fullmatch(requested):
        raise ValueError("Specify latest, all, a stable version, or checksummed custom installers")
    by_arch = {arch: catalog(arch, requested) for arch in PLATFORMS}
    if requested == "latest":
        versions = [list(by_arch[arch]) for arch in PLATFORMS]
        if any(len(items) != 1 for items in versions) or versions[0] != versions[1]:
            raise ValueError(f"Stable release is not yet available on both platforms: {versions}")
        return versions[0][0], [by_arch[arch][versions[0][0]] for arch in PLATFORMS]
    builds = [entry for installers in by_arch.values() for entry in installers.values()]
    if not builds:
        raise ValueError(f"No stable installer found for {requested}")
    return "", sorted(builds, key=lambda item: (tuple(map(int, item["version"].split("."))), item["arch"]))


def main():
    requested = os.environ.get("REQUESTED_VERSION", "latest")
    if os.environ.get("GITHUB_REF_TYPE") == "tag":
        requested = os.environ["GITHUB_REF_NAME"].removeprefix("v")
    image_name = os.environ.get("IMAGE_NAME", "unifi-os-server-docker")
    owner = os.environ["GITHUB_REPOSITORY_OWNER"].lower()
    if not IMAGE_NAME.fullmatch(image_name) or not IMAGE_NAME.fullmatch(owner):
        raise ValueError("Invalid GHCR image or repository owner name")
    overrides = []
    for arch in PLATFORMS:
        url = os.environ.get(f"INSTALLER_URL_{arch.upper()}", "")
        sha256 = os.environ.get(f"INSTALLER_SHA256_{arch.upper()}", "")
        if url or sha256:
            overrides.append((arch, url, sha256))
    latest, builds = resolve(requested, overrides)
    values = {
        "image": f"ghcr.io/{owner}/{image_name}",
        "latest": latest,
        "matrix": json.dumps(builds, separators=(",", ":")),
    }
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for name, value in values.items():
            print(f"{name}={value}", file=output)
    for build in builds:
        print(f"{build['tag']} for linux/{build['arch']}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(f"Unable to resolve UniFi release: {error}")
