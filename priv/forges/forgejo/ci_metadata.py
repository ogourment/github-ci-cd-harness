#!/usr/bin/env python3
"""Export trustworthy Forgejo identity and pipeline timing for acceptance evidence."""

import argparse
import datetime
import json
import os
import shlex
import sys
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def timing_environment(run, jobs, sha, repository, job_name, server):
    if run.get("commit_sha") != sha or run.get("repository", {}).get("full_name") != repository:
        raise ValueError("run identity mismatch")
    created = run["created"]
    timestamp = datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
    if timestamp.tzinfo is None or timestamp.year < 2000:
        raise ValueError("invalid creation timestamp")
    matches = [job for job in jobs if job.get("name") == job_name and job.get("status") == "running"]
    if len(matches) != 1 or matches[0].get("run_id") != run["id"]:
        raise ValueError("job attempt identity mismatch")
    job_id = matches[0]["id"]
    if not isinstance(job_id, int) or job_id <= 0:
        raise ValueError("invalid job identity")
    # Forgejo's job API supplies neither job creation time nor queued_duration.
    # Task creation is runner assignment, so it must not stand in for job creation.
    run_id = run["id"]
    number = run["index_in_repo"]
    if not isinstance(run_id, int) or run_id <= 0 or not isinstance(number, int) or number <= 0:
        raise ValueError("invalid run identity")
    url = f"{server}/{repository}/actions/runs/{number}"
    if run.get("html_url") != url:
        raise ValueError("run URL identity mismatch")
    return {"CI_PIPELINE_CREATED_AT": timestamp.isoformat(), "CI_JOB_ID": str(job_id),
            "CI_PIPELINE_ID": str(run_id), "CI_PIPELINE_URL": url, "CI_JOB_URL": url,
            "CI_CD_EXECUTION_RUN_ID": str(run_id), "CI_CD_EXECUTION_RUN_URL": url,
            "CI_CD_EXECUTION_CREATED_AT": timestamp.isoformat(),
            "CI_CD_METADATA_SOURCE": "forgejo_actions_api"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file")
    parser.add_argument("--shell", action="store_true")
    args = parser.parse_args()
    env = os.environ
    root = env["GITHUB_SERVER_URL"].rstrip("/")
    parsed = urlparse(root)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment:
        raise ValueError("invalid Forgejo server URL")
    opener = build_opener(NoRedirects())

    def fetch(path):
        request = Request(root + "/api/v1" + path, headers={"Authorization": "Bearer " + env["FORGEJO_TOKEN"]})
        with opener.open(request, timeout=10) as response:
            return json.load(response)

    # This endpoint resolves the actual run from its temporary workflow token.
    run = fetch("/actions/run")
    repository = env["GITHUB_REPOSITORY"]
    jobs = fetch(f"/repos/{repository}/actions/runs/{run['id']}/jobs")
    values = timing_environment(run, jobs, env["GITHUB_SHA"], repository, env["GITHUB_JOB"], root)
    with open(args.env_file or env["GITHUB_ENV"], "a", encoding="utf-8") as output:
        for name, value in values.items():
            if args.shell:
                output.write(f"export {name}={shlex.quote(value)}\n")
            else:
                output.write(f"{name}={value}\n")
    print("CI metadata: Forgejo run URL, pipeline timestamp and job identity exported; job wait and runner queue are not exposed by this API")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Timing is optional. Never disclose tokens, payloads or API error bodies.
        print("CI metadata: Forgejo metadata unavailable; leaving timings unknown", file=sys.stderr)
        sys.exit(1)
