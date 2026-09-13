#!/usr/bin/env python3
"""Fail closed before production mutation; gh uses the workflow's scoped token."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

from staging_receipt import receipt


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pages(path, key):
    result = []
    page = 1
    while True:
        batch = api(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")[key]
        result.extend(batch)
        if len(batch) < 100:
            return result
        page += 1


def verify(run, jobs, artifacts, recorded, actual, repository, workflow, artifact):
    require(run["repository"]["full_name"] == repository, "Wrong repository")
    require(run["path"] == workflow, "Wrong source workflow")
    require(run["head_branch"] == "main" and run["event"] in ("push", "workflow_dispatch"), "Untrusted source branch/event")
    require(run["status"] == "completed" and run["conclusion"] == "success", "Source run is not successful")
    require(any(j["name"].split(" / ")[-1] == "deploy_staging" and j["conclusion"] == "success" and j["run_attempt"] == run["run_attempt"] for j in jobs), "No successful staging job in this attempt")
    for name in (artifact, artifact + "-staging-verification"):
        matches = [a for a in artifacts if a["name"] == name]
        require(len(matches) == 1 and not matches[0]["expired"], "Missing, duplicate or expired artifact")
    require(recorded == actual, "Release bytes or identity differ from staging receipt")
    require(recorded["schema"] == 1 and recorded["repository"] == repository, "Invalid receipt scope")
    require(recorded["run_id"] == str(run["id"]) and recorded["run_attempt"] == str(run["run_attempt"]), "Source run changed or receipt is stale")
    require(recorded["sha"] == run["head_sha"] and recorded["artifact_name"] == artifact, "Wrong source identity")
    require(re.fullmatch(r"[0-9a-f]{40}", recorded["sha"]), "Invalid SHA")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", recorded["version"]), "Invalid version")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", recorded["release_id"]), "Invalid release ID")


def main():
    source = os.environ["SOURCE_RUN_ID"]
    require(re.fullmatch(r"[1-9][0-9]*", source), "Select an explicit numeric source run ID")
    repository = os.environ["GITHUB_REPOSITORY"]
    prefix = f"repos/{repository}/actions/runs/{source}"
    run = api(prefix)
    recorded = json.loads(Path("_verification/staging-verification.json").read_text())
    # Recompute using the SOURCE identity, never the promotion workflow's commit.
    os.environ.update(GITHUB_RUN_ID=source, GITHUB_RUN_ATTEMPT=str(run["run_attempt"]), GITHUB_SHA=run["head_sha"])
    verify(run, pages(prefix + "/jobs?filter=latest", "jobs"), pages(prefix + "/artifacts", "artifacts"), recorded, receipt("_build"), repository, os.environ["SOURCE_WORKFLOW"], os.environ["RELEASE_ARTIFACT_NAME"])
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"sha={recorded['sha']}\nrelease_id={recorded['release_id']}\nversion={recorded['version']}\n")
    print(f"Verified staging artifact {recorded['release_id']} from run {source}, attempt {run['run_attempt']}")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Promotion refused: {error}")
