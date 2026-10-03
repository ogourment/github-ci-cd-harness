#!/usr/bin/env python3
"""Verified deployment ranges, independent of checkout depth and notification transport."""

import argparse
import html
import json
import os
from pathlib import Path
import re
import subprocess


class RangeUnavailable(Exception):
    pass


def git(*args, timeout=10):
    result = subprocess.run(["git", *args], capture_output=True, timeout=timeout)
    if result.returncode:
        raise RangeUnavailable("required Git history is unavailable")
    return result.stdout.decode("utf-8", errors="replace").strip()


def resolve(sha):
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{7,40}", sha):
        raise RangeUnavailable("deployment commit identity is missing or malformed")
    return git("rev-parse", "--verify", sha + "^{commit}")


def previous_identity(env, target):
    explicit = env.get("CI_CD_PREVIOUS_DEPLOYED_SHA")
    if explicit:
        return explicit, "explicit_previous_deployment"
    health_path = env.get("CI_CD_PREVIOUS_HEALTH_FILE", f"_build/deployment/{target}/previous_health.json")
    try:
        health = json.loads(Path(health_path).read_text())
    except (OSError, ValueError):
        raise RangeUnavailable("previous deployment identity was not observed")
    if not isinstance(health, dict):
        raise RangeUnavailable("previous health response is malformed")
    sha = health.get("git_sha") or health.get("commit_sha")
    if sha:
        return sha, "previous_health_commit"
    release_id = health.get("release_id", "")
    release = release_id.rsplit("-", 2) if isinstance(release_id, str) else []
    if len(release) == 3 and re.fullmatch(r"[0-9a-fA-F]{7,40}", release[1]):
        return release[1], "previous_health_release"
    raise RangeUnavailable("previous health response has no deployment commit identity")


def execution_id(env):
    return env.get("CI_CD_EXECUTION_RUN_ID") or env.get("GITHUB_RUN_ID") or env.get("CI_PIPELINE_ID", "")


def collect(env, target):
    report = {"target": target, "pipeline_id": execution_id(env), "source_pipeline_id": env.get("CI_PIPELINE_ID", ""), "status": "unavailable"}
    try:
        report["head"] = resolve(env.get("CI_COMMIT_SHA") or git("rev-parse", "HEAD"))
        previous, source = previous_identity(env, target)
        report["source"] = source
        if not isinstance(previous, str) or not re.fullmatch(r"[0-9a-fA-F]{7,40}", previous):
            raise RangeUnavailable("previous deployment commit identity is malformed")
        if git("rev-parse", "--is-shallow-repository") == "true":
            if env.get("CI_CD_COMMIT_HISTORY_FETCH", "true") != "true":
                raise RangeUnavailable("shallow checkout; history fetching is disabled")
            git("fetch", "--no-tags", "--unshallow", "origin", timeout=30)
            if git("rev-parse", "--is-shallow-repository") == "true":
                raise RangeUnavailable("checkout history remains incomplete")
        try:
            base = resolve(previous)
        except RangeUnavailable:
            if len(previous) != 40 or env.get("CI_CD_COMMIT_HISTORY_FETCH", "true") != "true":
                raise
            git("fetch", "--no-tags", "origin", previous, timeout=30)
            base = resolve(previous)
        report["base"] = base
        if base == report["head"]:
            direction, lower, upper = "unchanged", base, base
        else:
            def ancestor(left, right):
                result = subprocess.run(["git", "merge-base", "--is-ancestor", left, right], capture_output=True, timeout=10)
                if result.returncode not in (0, 1):
                    raise RangeUnavailable("commit ancestry cannot be verified")
                return result.returncode == 0
            if ancestor(base, report["head"]):
                direction, lower, upper = "forward", base, report["head"]
            elif ancestor(report["head"], base):
                direction, lower, upper = "rollback", report["head"], base
            else:
                raise RangeUnavailable("deployment histories diverge; no linear deployment range")
        fields = git("log", "--reverse", "--format=%H%x00%s%x00%B%x00", f"{lower}..{upper}").split("\0")
        commits = []
        for index in range(0, len(fields) - 1, 3):
            sha, subject, message = fields[index:index + 3]
            commits.append({"sha": sha.strip(), "subject": subject, "message": message})
        report.update(status="available", direction=direction, count=len(commits), commits=commits)
    except (RangeUnavailable, subprocess.TimeoutExpired) as error:
        report["reason"] = str(error) if isinstance(error, RangeUnavailable) else "Git history lookup exceeded its deadline"
    return report


def render(report):
    if report["status"] != "available":
        return "Commits: unavailable — " + html.escape(report.get("reason", "deployment range unavailable"))
    label = "Commits removed (rollback)" if report["direction"] == "rollback" else "Commits"
    lines = [f"{label}: {report['count']}"]
    if not report["count"]:
        lines[0] += " (same release commit)"
    printed = 0
    for commit in report["commits"]:
        subject = commit["subject"][:200]
        line = f"- <code>{commit['sha'][:8]}</code> {html.escape(subject)}"
        if len(commit["subject"]) > 200:
            line += "…"
        if len("\n".join([*lines, line]).encode("utf-16-le")) // 2 > 2000:
            break
        lines.append(line)
        printed += 1
    if printed < report["count"]:
        lines.append(f"… {report['count'] - printed} more; complete list in deployment report")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["collect", "render", "messages"])
    parser.add_argument("target")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", args.target):
        parser.error("invalid deployment target")
    path = Path("_build/deployment") / args.target / "commits.json"
    if args.action == "collect":
        report = collect(os.environ, args.target)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(path)
        print(report["status"])
        return
    if path.exists():
        try:
            report = json.loads(path.read_text())
            expected_head = resolve(os.environ.get("CI_COMMIT_SHA") or git("rev-parse", "HEAD"))
            if (report.get("head"), report.get("target"), report.get("pipeline_id")) != (expected_head, args.target, execution_id(os.environ)):
                raise RangeUnavailable("deployment report identity does not match this run")
        except (OSError, ValueError, AttributeError, RangeUnavailable, subprocess.TimeoutExpired):
            report = {"status": "unavailable", "reason": "deployment report is malformed or does not match this run"}
    elif os.environ.get("CI_CD_PREVIOUS_DEPLOYED_SHA") or os.environ.get("CI_CD_PREVIOUS_HEALTH_FILE"):
        report = collect(os.environ, args.target)
    else:
        report = {"status": "unavailable", "reason": "deployment report was not prepared for this job"}
    if args.action == "render":
        print(render(report))
    elif report["status"] == "available":
        prefix = "removed " if report["direction"] == "rollback" else ""
        print("\n".join(prefix + c["sha"][:8] + " " + c["subject"] for c in report["commits"]))
    else:
        print("Commit range unavailable: " + report.get("reason", "deployment range unavailable"))


if __name__ == "__main__":
    main()
