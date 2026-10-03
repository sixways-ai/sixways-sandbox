#!/usr/bin/env python3
"""Fail the image build if either documented pip SBOM exception becomes unsafe."""

import importlib.metadata
from pathlib import Path

import pip
from pip._vendor import msgpack
from pip._vendor.packaging.version import Version


def check() -> None:
    if Version(msgpack.__version__) < Version("1.2.1"):
        raise RuntimeError("pip's installed msgpack needs GHSA-6v7p-g79w-8964 fixed")

    vendor = Path(pip.__file__).parent / "_vendor"
    if list(vendor.rglob("package_index.*")):
        raise RuntimeError("Review pip's bundled PackageIndex before accepting CVE-2025-47273")

    # Also reject affected standalone copies; an exception must not hide them.
    minimums = {"msgpack": "1.2.1", "setuptools": "78.1.1"}
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata.get("Name", "").lower()
        if name in minimums and Version(distribution.version) < Version(minimums[name]):
            raise RuntimeError(f"Installed {name} {distribution.version} is vulnerable")


if __name__ == "__main__":
    check()
