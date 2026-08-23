#!/usr/bin/env bash
set -euo pipefail

phase="${1:-complete}"
plan="${ACCEPTANCE_SELECTION_PLAN:-tmp/acceptance-selection.json}"
evidence_dir="${ACCEPTANCE_EVIDENCE_DIR:-tmp/atdd}"
if [ "$phase" = "staging" ]; then
  evidence_dir="${ACCEPTANCE_FAST_EVIDENCE_DIR:-tmp/atdd-fast}"
fi

jobs_json=""
if [ -n "${CI_API_V4_URL:-}" ] && [ -n "${CI_PROJECT_ID:-}" ] && [ -n "${CI_PIPELINE_ID:-}" ] && [ -n "${CI_JOB_TOKEN:-}" ]; then
  jobs_json="$(mktemp)"
  trap 'rm -f "$jobs_json"' EXIT
  curl -fsS --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}/jobs?per_page=100&include_retried=false" \
    >"$jobs_json" || : >"$jobs_json"
fi

python3 - "$phase" "$plan" "$evidence_dir/evidence.json" "$jobs_json" <<'PY'
import json, os, re, subprocess, sys

phase, plan_path, evidence_path, jobs_path = sys.argv[1:]

def load(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default

def duration(value):
    if value is None:
        return "pending"
    value = max(0, int(round(value)))
    return f"{value // 60}m {value % 60}s"

plan = load(plan_path, {})
evidence = load(evidence_path, {})
jobs = load(jobs_path, []) if jobs_path else []
selected = plan.get("fast", {}).get("scenario_ids", [])
remaining = plan.get("remaining", {}).get("scenario_ids", [])
scenarios = evidence.get("scenarios", [])
counts = {}
for scenario in scenarios:
    status = scenario.get("status", "unknown")
    counts[status] = counts.get(status, 0) + 1

if not scenarios:
    markdown_path = os.path.join(os.path.dirname(evidence_path), "e2e.md")
    try:
        with open(markdown_path, encoding="utf-8") as handle:
            markdown = handle.read()
    except OSError:
        markdown = ""
    icons = {"✅": "success", "❌": "failure", "🟠": "ignored", "⬛": "skipped", "⏭": "skipped"}
    for line in markdown.splitlines():
        match = re.match(r"^\|\s*\d+\s*\|\s*([^|]+)\|", line)
        if match:
            for icon, status in icons.items():
                if icon in match.group(1):
                    counts[status] = counts.get(status, 0) + 1
                    break

if phase == "staging":
    if remaining:
        print("<b>Fast acceptance:</b> staging is ready; full acceptance continues")
    else:
        print("<b>Acceptance:</b> staging is ready; the full suite is already complete")
else:
    print("<b>Combined acceptance:</b> all required phases assembled")

areas = plan.get("areas", [])
markers = plan.get("markers", [])
print(f"Selection: <code>{plan.get('mode', 'unknown')}</code> · fast <code>{len(selected)}</code> · remaining <code>{len(remaining)}</code>")
if areas:
    print("Areas: " + " ".join(f"#{area}" for area in areas))
if markers:
    print("Commit markers: " + " ".join(f"#{marker}" for marker in markers))
if counts:
    rendered = ", ".join(f"{key}={counts[key]}" for key in sorted(counts))
    print(f"Results: {rendered}")

try:
    base = os.environ.get("CI_COMMIT_BEFORE_SHA", "")
    head = os.environ.get("CI_COMMIT_SHA", "HEAD")
    if base and set(base) != {"0"}:
        output = subprocess.check_output(["git", "log", "--no-merges", "--pretty=format:%h %s", f"{base}..{head}"], text=True)
    else:
        output = subprocess.check_output(["git", "log", "--no-merges", "--pretty=format:%h %s", "-n", "10", head], text=True)
    commits = [line for line in output.splitlines() if line]
except (OSError, subprocess.SubprocessError):
    commits = []
if commits:
    print(f"Commits: <code>{len(commits)}</code>")
    for commit in commits[:10]:
        print("- " + commit.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

interesting = {"acceptance_fast", "build_release", "deploy_staging", "staging_release_smoke", "acceptance_evidence", "ecoindex_staging", "acceptance_gate"}
timed = [job for job in jobs if job.get("name") in interesting]
if timed:
    print("<b>Pipeline jobs:</b>")
    for job in sorted(timed, key=lambda item: item.get("id", 0)):
        if str(job.get("id")) == os.environ.get("CI_JOB_ID") and os.environ.get("CI_JOB_STATUS"):
            job["status"] = os.environ["CI_JOB_STATUS"]
        queued = job.get("queued_duration")
        print(f"- {job.get('name')}: {job.get('status')} · elapsed <code>{duration(job.get('duration'))}</code> · queued <code>{duration(queued)}</code>")
    pending = [job["name"] for job in timed if job.get("status") in {"created", "pending", "running"}]
    if pending:
        print("Pending: " + ", ".join(pending))

report_url = os.environ.get("ACCEPTANCE_REPORT_URL") or os.environ.get("CI_JOB_URL")
if report_url:
    print(f'Evidence: <a href="{report_url}">open report</a>')
PY
