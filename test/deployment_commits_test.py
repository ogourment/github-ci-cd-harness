"""Deployment ranges use deployed state, not push boundaries or checkout depth."""

import importlib.util
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("commits", ROOT / "priv/core/deployment_commits.py")
COMMITS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMMITS)


class DeploymentCommitsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.previous_cwd = Path.cwd()
        self.addCleanup(os.chdir, self.previous_cwd)
        self.repo = Path(self.temporary.name) / "repository"
        self.repo.mkdir()
        os.chdir(self.repo)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "delivery@example.test")
        self.git("config", "user.name", "Delivery Test")
        self.git("config", "core.hooksPath", "/dev/null")
        self.shas = []
        for subject in ["Previously deployed", "First change #invitations", "Second change\n\n#accounts", "Third change"]:
            self.shas.append(self.commit(subject))
        self.env = {"CI_COMMIT_SHA": self.shas[-1], "CI_CD_PREVIOUS_DEPLOYED_SHA": self.shas[0], "CI_COMMIT_BEFORE_SHA": self.shas[-2], "GITHUB_RUN_ID": ""}

    def git(self, *args):
        return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL, text=True).strip()

    def commit(self, subject):
        # These contracts concern commit ancestry/messages, not working files.
        self.git("commit", "--allow-empty", "-q", "-m", subject)
        return self.git("rev-parse", "HEAD")

    def test_range_spans_multiple_pushes(self):
        report = COMMITS.collect(self.env, "staging")
        self.assertEqual(report["count"], 3)
        self.assertEqual([c["sha"] for c in report["commits"]], self.shas[1:])
        self.assertIn("#invitations", COMMITS.render(report))
        self.assertIn("#accounts", report["commits"][1]["message"])

    def test_redeploy_has_zero_commits(self):
        self.env["CI_CD_PREVIOUS_DEPLOYED_SHA"] = self.shas[-1]
        report = COMMITS.collect(self.env, "staging")
        self.assertEqual(report["count"], 0)
        self.assertEqual(report["direction"], "unchanged")
        self.assertIn("Commits: 0", COMMITS.render(report))

    def test_rollback_names_removed_commits(self):
        self.env.update(CI_COMMIT_SHA=self.shas[0], CI_CD_PREVIOUS_DEPLOYED_SHA=self.shas[-1])
        report = COMMITS.collect(self.env, "prod")
        self.assertEqual(report["direction"], "rollback")
        self.assertEqual(report["count"], 3)
        self.assertIn("Commits removed (rollback): 3", COMMITS.render(report))

    def test_missing_deployed_state_does_not_claim_one_commit(self):
        del self.env["CI_CD_PREVIOUS_DEPLOYED_SHA"]
        self.env["CI_CD_PREVIOUS_HEALTH_FILE"] = str(self.repo / "missing.json")
        report = COMMITS.collect(self.env, "staging")
        self.assertEqual(report["status"], "unavailable")
        self.assertNotIn("count", report)
        self.assertIn("Commits: unavailable", COMMITS.render(report))

    def test_shallow_clone_is_hydrated_before_counting(self):
        clone = Path(self.temporary.name) / "clone"
        self.git("clone", "-q", "--depth=1", self.repo.as_uri(), str(clone))
        os.chdir(clone)
        report = COMMITS.collect(self.env, "staging")
        self.assertEqual(report["count"], 3)
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository"), "false")

    def test_unavailable_history_is_reported_without_partial_count(self):
        clone = Path(self.temporary.name) / "clone"
        self.git("clone", "-q", "--depth=1", self.repo.as_uri(), str(clone))
        os.chdir(clone)
        self.env["CI_CD_COMMIT_HISTORY_FETCH"] = "false"
        report = COMMITS.collect(self.env, "staging")
        self.assertEqual(report["status"], "unavailable")
        self.assertNotIn("count", report)

    def test_divergent_deployments_are_not_reported_as_forward(self):
        self.git("checkout", "-q", "-b", "other", self.shas[0])
        self.env["CI_COMMIT_SHA"] = self.commit("Other history")
        self.env["CI_CD_PREVIOUS_DEPLOYED_SHA"] = self.shas[-1]
        report = COMMITS.collect(self.env, "prod")
        self.assertEqual(report["status"], "unavailable")
        self.assertIn("diverge", report["reason"])

    def test_previous_health_release_resolves_deployment_boundary(self):
        health = self.repo / "previous.json"
        health.write_text(json.dumps({"release_id": f"v0.3.28-{self.shas[0][:8]}-2403"}))
        del self.env["CI_CD_PREVIOUS_DEPLOYED_SHA"]
        self.env["CI_CD_PREVIOUS_HEALTH_FILE"] = str(health)
        self.assertEqual(COMMITS.collect(self.env, "prod")["count"], 3)

    def test_transport_budget_preserves_complete_total_and_report(self):
        report = COMMITS.collect(self.env, "staging")
        report["commits"] *= 20
        report["count"] = len(report["commits"])
        report["commits"][0]["subject"] = "<script>& " + "😀" * 1000
        message = COMMITS.render(report)
        self.assertIn("Commits: 60", message)
        self.assertIn("more; complete list", message)
        self.assertNotIn("<script>", message)
        self.assertLess(len(message.encode("utf-16-le")) // 2, 2300)
        self.assertEqual(len(report["commits"]), 60)

    def test_notifier_uses_prepared_report_and_keeps_all_three_commits(self):
        environment = dict(os.environ, **self.env, CI_CD_DEPLOY_TARGET="staging", TELEGRAM_BOT_TOKEN="", TELEGRAM_CHAT_ID="", CI_CD_ALERT_ADAPTER="")
        subprocess.run(["python3", str(ROOT / "priv/core/deployment_commits.py"), "collect", "staging"], env=environment, check=True, capture_output=True)
        del environment["CI_CD_PREVIOUS_DEPLOYED_SHA"]
        environment["CI_CD_PREVIOUS_HEALTH_FILE"] = str(self.repo / "missing.json")
        Path("_build/VERSION").write_text("0.3.29")
        Path("_build/RELEASE_ID").write_text("v0.3.29-test-1")
        result = subprocess.run(["bash", str(ROOT / "priv/core/notify_deployment.sh")], env=environment, capture_output=True, text=True, check=True)
        self.assertIn("Commits: 3", result.stdout)
        self.assertIn("First change", result.stdout)
        self.assertIn("Third change", result.stdout)

    def test_notifier_uses_actual_deploy_duration_not_entire_job_runtime(self):
        directory = Path("_build/deployment/staging")
        directory.mkdir(parents=True)
        (directory / "timing.env").write_text("CI_CD_DEPLOY_STARTED_AT_EPOCH=100\nCI_CD_DEPLOY_FINISHED_AT_EPOCH=110\nCI_CD_DEPLOY_EXIT_CODE=0\n")
        environment = dict(os.environ, **self.env, CI_CD_DEPLOY_TARGET="staging", CI_JOB_STARTED_AT="2026-01-01T00:00:00Z", TELEGRAM_BOT_TOKEN="", TELEGRAM_CHAT_ID="", CI_CD_ALERT_ADAPTER="")
        result = subprocess.run(["bash", str(ROOT / "priv/core/notify_deployment.sh")], env=environment, capture_output=True, text=True, check=True)
        self.assertIn("deploy=<code>0m 10s</code>", result.stdout)
        self.assertIn("wait=<code>unknown</code>", result.stdout)

    def test_corrupt_or_stale_report_does_not_claim_a_commit_count(self):
        environment = dict(os.environ, **self.env, CI_CD_DEPLOY_TARGET="staging", CI_PIPELINE_ID="1")
        script = str(ROOT / "priv/core/deployment_commits.py")
        subprocess.run(["python3", script, "collect", "staging"], env=environment, check=True, capture_output=True)
        environment["CI_PIPELINE_ID"] = "2"
        result = subprocess.run(["python3", script, "render", "staging"], env=environment, capture_output=True, text=True, check=True)
        self.assertIn("Commits: unavailable", result.stdout)
        self.assertNotIn("Commits: 3", result.stdout)
        Path("_build/deployment/staging/commits.json").write_text("broken JSON")
        result = subprocess.run(["python3", script, "render", "staging"], env=environment, capture_output=True, text=True, check=True)
        self.assertIn("Commits: unavailable", result.stdout)

    def test_shared_deployer_transports_the_verified_range_and_records_timing(self):
        binary = self.repo / "fake-bin"
        binary.mkdir()
        home = self.repo / "home"
        home.mkdir()
        build = self.repo / "_build"
        build.mkdir()
        release = f"v0.3.29-{self.shas[-1][:8]}-999"
        (build / "VERSION").write_text("0.3.29")
        (build / "RELEASE_ID").write_text(release)
        (build / "release").mkdir()
        previous = {"version": "0.3.28", "release_id": f"v0.3.28-{self.shas[0][:8]}-888", "pipeline_id": "888"}
        current = {"version": "0.3.29", "release_id": release, "pipeline_id": "999"}
        scripts = {
            "ssh": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CI_FAKE_SSH_LOG"\n',
            "rsync": "#!/bin/sh\nexit 0\n",
            "curl": "#!/usr/bin/env python3\nfrom pathlib import Path\nimport os,json\np=Path(os.environ['CI_FAKE_CURL_STATE'])\nfirst=not p.exists()\np.write_text('called')\nprint(os.environ['CI_FAKE_PREVIOUS_HEALTH'] if first else os.environ['CI_FAKE_CURRENT_HEALTH'])\n",
        }
        for name, content in scripts.items():
            executable = binary / name
            executable.write_text(content)
            executable.chmod(0o755)
        environment = dict(os.environ, **self.env, PATH=str(binary) + os.pathsep + os.environ["PATH"], HOME=str(home),
                           FORGEJO_TOKEN="", CI_JOB_TOKEN="", CI_API_V4_URL="", CI_PIPELINE_ID="999",
                           CI_CD_OTP_APP="report_app", CI_CD_REMOTE_ENV_PREFIX="REPORT_APP", CI_CD_DEPLOY_HOST="staging.example.test",
                           CI_CD_DEPLOY_SSH_PRIVATE_KEY="fixture-key", CI_CD_DEPLOY_SSH_KNOWN_HOSTS="fixture-host",
                           CI_CD_REMOTE_DEPLOY_SCRIPT="/fixture/deploy", CI_CD_RELEASE_ARTIFACT_PATH=str(build / "release"),
                           CI_CD_HEALTH_URL="https://staging.example.test/health", CI_CD_WEBSOCKET_BASE_URL="",
                           CI_FAKE_SSH_LOG=str(self.repo / "ssh.log"), CI_FAKE_CURL_STATE=str(self.repo / "curl.state"),
                           CI_FAKE_PREVIOUS_HEALTH=json.dumps(previous), CI_FAKE_CURRENT_HEALTH=json.dumps(current))
        del environment["CI_CD_PREVIOUS_DEPLOYED_SHA"]
        result = subprocess.run(["bash", str(ROOT / "priv/core/deploy_release_fast.sh"), "staging"], env=environment,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads((build / "deployment/staging/commits.json").read_text())
        relative_report = (build / "deployment/staging/commits.json").relative_to(self.repo).as_posix()
        github = (ROOT / ".github/workflows/phoenix-delivery.yml").read_text()
        gitlab = (ROOT / "templates/gitlab/cd.yml").read_text()
        self.assertIn(relative_report, github)
        upload_paths = [line.strip()[2:] for line in gitlab.splitlines() if line.strip().startswith("- _build/deployment/")]
        self.assertTrue(any(fnmatch.fnmatch(relative_report, path) for path in upload_paths))
        self.assertEqual(report["base"], self.shas[0])
        self.assertEqual(report["count"], 3)
        ssh = (self.repo / "ssh.log").read_text()
        self.assertIn("First", ssh)
        self.assertIn("Third", ssh)
        self.assertIn("CI_CD_DEPLOY_EXIT_CODE=0", (build / "deployment/staging/timing.env").read_text())


if __name__ == "__main__":
    unittest.main()
