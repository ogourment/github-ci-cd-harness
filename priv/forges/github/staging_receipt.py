#!/usr/bin/env python3
"""Bind downloaded release bytes to the staging deployment that verified them."""
import hashlib
import json
import os
from pathlib import Path


def receipt(directory):
    root = Path(directory)
    digest = hashlib.sha256()
    with (root / "release.tar.gz").open("rb") as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "schema": 1,
        "repository": os.environ["GITHUB_REPOSITORY"],
        "run_id": os.environ["GITHUB_RUN_ID"],
        "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "sha": os.environ["GITHUB_SHA"],
        "artifact_name": os.environ["RELEASE_ARTIFACT_NAME"],
        "version": (root / "VERSION").read_text().strip(),
        "release_id": (root / "RELEASE_ID").read_text().strip(),
        "sha256": digest.hexdigest(),
    }


if __name__ == "__main__":
    print(json.dumps(receipt("_build"), sort_keys=True))
