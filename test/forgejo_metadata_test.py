"""Identity and timing checks without a live workflow token."""

import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "timing", Path(__file__).resolve().parents[1] / "priv/forges/forgejo/ci_metadata.py"
)
TIMING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TIMING)


class TimingTest(unittest.TestCase):
    def setUp(self):
        self.run = {"id": 2432, "commit_sha": "abc", "created": "2026-10-02T20:32:39Z",
                    "repository": {"full_name": "olivierg/punnles"}, "index_in_repo": 115,
                    "html_url": "https://git.agile-u.com/olivierg/punnles/actions/runs/115"}
        self.jobs = [{"id": 4140, "run_id": 2432, "name": "acceptance_evidence", "status": "running"}]

    def capture(self):
        return TIMING.timing_environment(self.run, self.jobs, "abc", "olivierg/punnles", "acceptance_evidence", "https://git.agile-u.com")

    def test_exports_provider_timestamp_and_actual_job_id(self):
        values = self.capture()
        self.assertEqual(values["CI_PIPELINE_CREATED_AT"], "2026-10-02T20:32:39+00:00")
        self.assertEqual(values["CI_JOB_ID"], "4140")
        self.assertEqual(values["CI_PIPELINE_ID"], "2432")
        self.assertTrue(values["CI_PIPELINE_URL"].endswith("/115"))
        self.assertNotIn("CI_JOB_CREATED_AT", values)

    def test_rejects_another_revision(self):
        self.run["commit_sha"] = "other"
        with self.assertRaises(ValueError):
            self.capture()

    def test_rejects_another_attempt_or_run(self):
        self.jobs[0]["run_id"] = 2420
        with self.assertRaises(ValueError):
            self.capture()
        self.jobs[0]["run_id"] = 2432
        self.jobs.append(dict(self.jobs[0]))
        with self.assertRaises(ValueError):
            self.capture()

    def test_rejects_timestamp_injection(self):
        self.run["created"] += "\nCI_JOB_CREATED_AT=fake"
        with self.assertRaises(ValueError):
            self.capture()

    def test_rejects_a_url_for_the_api_id_instead_of_the_ui_run(self):
        self.run["html_url"] = "https://git.agile-u.com/olivierg/punnles/actions/runs/2432"
        with self.assertRaises(ValueError):
            self.capture()

    def test_workflow_token_reads_only_current_run_and_writes_no_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "metadata.env"
            environment = {"GITHUB_SERVER_URL": "https://git.agile-u.com", "GITHUB_REPOSITORY": "olivierg/punnles",
                           "GITHUB_SHA": "abc", "GITHUB_JOB": "acceptance_evidence", "FORGEJO_TOKEN": "fixture-workflow-token"}
            requests = []
            def fetch(request, timeout):
                requests.append(request)
                payload = self.run if request.full_url.endswith("/actions/run") else self.jobs
                return io.StringIO(json.dumps(payload))
            opener = mock.Mock()
            opener.open.side_effect = fetch
            with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(sys, "argv", ["ci_metadata.py", "--env-file", str(output), "--shell"]), mock.patch.object(TIMING, "build_opener", return_value=opener):
                TIMING.main()
            written = output.read_text()
            self.assertIn("CI_JOB_ID=4140", written)
            self.assertIn("/actions/runs/115", written)
            self.assertNotIn("fixture-workflow-token", written)
            self.assertNotIn("CI_JOB_CREATED_AT", written)
            self.assertEqual([r.full_url for r in requests], ["https://git.agile-u.com/api/v1/actions/run",
                             "https://git.agile-u.com/api/v1/repos/olivierg/punnles/actions/runs/2432/jobs"])
            self.assertTrue(all(r.get_header("Authorization") == "Bearer fixture-workflow-token" for r in requests))

    def test_promotion_preserves_source_pipeline_and_exposes_execution_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "bin"
            binary.mkdir()
            python = binary / "python3"
            python.write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n  if [ "$1" = "--env-file" ]; then dst="$2"; shift 2; else shift; fi\ndone\ncp "$CI_FAKE_METADATA" "$dst"\n')
            python.chmod(0o755)
            metadata = root / "fixture.env"
            metadata.write_text("export CI_PIPELINE_ID=777\nexport CI_PIPELINE_URL=https://git.agile-u.com/olivierg/app/actions/runs/12\nexport CI_PIPELINE_CREATED_AT=2026-10-02T20:32:39Z\nexport CI_CD_EXECUTION_RUN_ID=777\nexport CI_CD_EXECUTION_RUN_URL=https://git.agile-u.com/olivierg/app/actions/runs/12\nexport CI_CD_EXECUTION_CREATED_AT=2026-10-02T20:32:39Z\nexport CI_JOB_ID=999\n")
            environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"], CI_FAKE_METADATA=str(metadata),
                               GITHUB_RUN_ID="777", GITHUB_SERVER_URL="https://git.agile-u.com", GITHUB_REPOSITORY="olivierg/app",
                               FORGEJO_TOKEN="fixture-token", CI_PIPELINE_ID="321", CI_PIPELINE_URL="https://source.example.test/321")
            helper = Path(__file__).resolve().parents[1] / "priv/core/ci_metadata.sh"
            result = subprocess.run(["bash", "-c", 'source "$1"; printf "%s\\n" "$CI_PIPELINE_ID" "$CI_PIPELINE_URL" "$CI_CD_EXECUTION_RUN_ID" "$CI_JOB_ID" "${CI_PIPELINE_CREATED_AT:-unknown}"', "bash", str(helper)],
                                    env=environment, text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.splitlines(), ["321", "https://source.example.test/321", "777", "999", "unknown"])


if __name__ == "__main__":
    unittest.main()
