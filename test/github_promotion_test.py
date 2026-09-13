"""Offline, real-entrypoint staging receipt and promotion contracts."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "priv/forges/github"
sys.path.insert(0, str(SCRIPTS))
from verify_promotion import verify


class PromotionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "_build").mkdir()
        (self.root / "_verification").mkdir()
        for name, value in (("VERSION", "1.2.3\n"), ("RELEASE_ID", "demo-1.2.3-42\n"), ("release.tar.gz", "exact staged bytes")):
            (self.root / "_build" / name).write_text(value)
        self.env = dict(os.environ, GITHUB_REPOSITORY="owner/app", GITHUB_RUN_ID="42", GITHUB_RUN_ATTEMPT="1", GITHUB_SHA="a" * 40, RELEASE_ARTIFACT_NAME="demo-release", SOURCE_RUN_ID="42", SOURCE_WORKFLOW=".github/workflows/ci.yml", GITHUB_OUTPUT=str(self.root / "outputs"))
        result = subprocess.run([sys.executable, str(SCRIPTS / "staging_receipt.py")], cwd=self.root, env=self.env, capture_output=True, text=True, check=True)
        self.recorded = json.loads(result.stdout)
        (self.root / "_verification/staging-verification.json").write_text(result.stdout)
        self.run = dict(id=42, run_attempt=1, repository=dict(full_name="owner/app"), path=".github/workflows/ci.yml", head_branch="main", head_sha="a" * 40, event="push", status="completed", conclusion="success")
        self.jobs = [dict(name="delivery / deploy_staging", conclusion="success", run_attempt=1)]
        self.artifacts = [dict(name=n, expired=False) for n in ("demo-release", "demo-release-staging-verification")]

    def check(self, actual=None):
        verify(self.run, self.jobs, self.artifacts, self.recorded, actual or self.recorded, "owner/app", ".github/workflows/ci.yml", "demo-release")

    def invoke(self):
        (self.root / "api.json").write_text(json.dumps(dict(run=self.run, jobs=self.jobs, artifacts=self.artifacts)))
        gh = self.root / "gh"
        gh.write_text("#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\nd=json.loads(Path('api.json').read_text())\np=sys.argv[2]\nprint(json.dumps({'jobs':d['jobs']} if '/jobs?' in p else {'artifacts':d['artifacts']} if '/artifacts?' in p else d['run']))\n")
        gh.chmod(0o755)
        env = dict(self.env, PATH=str(self.root) + os.pathsep + self.env["PATH"], GITHUB_RUN_ID="999", GITHUB_SHA="b" * 40)
        return subprocess.run([sys.executable, str(SCRIPTS / "verify_promotion.py")], cwd=self.root, env=env, capture_output=True, text=True)

    def test_promotes_original_identity_not_current_main(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = (self.root / "outputs").read_text()
        self.assertIn("sha=" + "a" * 40, outputs)
        self.assertIn("release_id=demo-1.2.3-42", outputs)
        self.assertEqual((self.root / "_build/release.tar.gz").read_text(), "exact staged bytes")

    def test_tampered_archive_never_becomes_deployable(self):
        (self.root / "_build/release.tar.gz").write_text("replacement")
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse((self.root / "outputs").exists())

    def test_untrusted_or_incomplete_runs_fail_closed(self):
        original = copy.deepcopy(self.run)
        for fields in (dict(repository=dict(full_name="other/app")), dict(path="other.yml"), dict(head_branch="feature"), dict(event="pull_request"), dict(status="in_progress"), dict(conclusion="failure"), dict(run_attempt=2), dict(head_sha="b" * 40)):
            with self.subTest(fields=fields):
                self.run = dict(original, **fields)
                with self.assertRaises(ValueError):
                    self.check()

    def test_failed_skipped_or_previous_staging_attempt_is_rejected(self):
        original = copy.deepcopy(self.jobs[0])
        for fields in (dict(conclusion="failure"), dict(conclusion="skipped"), dict(run_attempt=2), dict(name="not_deploy_staging")):
            with self.subTest(fields=fields):
                self.jobs = [dict(original, **fields)]
                with self.assertRaises(ValueError):
                    self.check()

    def test_expired_missing_or_duplicate_artifacts_are_rejected(self):
        original = copy.deepcopy(self.artifacts)
        for artifacts in ([], [original[0]], original + [original[0]], [dict(original[0], expired=True), original[1]]):
            with self.subTest(artifacts=artifacts):
                self.artifacts = artifacts
                with self.assertRaises(ValueError):
                    self.check()

    def test_changed_metadata_cannot_use_old_receipt(self):
        for field in ("version", "release_id", "sha256"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check(dict(self.recorded, **{field: "changed"}))

    def test_requires_explicit_run_id(self):
        self.env["SOURCE_RUN_ID"] = "latest"
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse((self.root / "outputs").exists())


if __name__ == "__main__":
    unittest.main()
