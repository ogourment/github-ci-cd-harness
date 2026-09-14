# Changelog

## 0.4.42

- Add opt-in application-aware blue/green retirement. The shared deploy path
  drains the old owner, waits for explicit `safe_to_stop`, fences it, verifies
  candidate promotion, and only then retires the old slot. A blocked pre-fence
  drain restores the old route and resumes its claims without stopping it.

## 0.4.41

- Add a production-only Phoenix promotion workflow and copy-ready GitHub CI,
  staging and manual-promotion callers. Promotion downloads an explicit successful
  staging run's artifact, verifies its byte digest and staging receipt, preserves
  its commit/version/release ID, and reuses the existing deployment and tagging
  core without rebuilding or redeploying staging. Missing/expired artifacts,
  untrusted runs and stale attempts fail before production mutation. Production
  promotion and combined delivery share a non-cancelling concurrency group.
- Record staging receipts only after deployed identity and HTML smoke checks;
  pin shared delivery scripts to the harness release. Stage-only delivery no
  longer requires production credentials.

## 0.4.40

- Package acceptance evidence in the exact Phoenix release artifact when both
  browser acceptance and release builds are enabled. Previously evidence was
  retained on GitHub but never transported by the delivery job, leaving live
  acceptance stores stale despite green tests. Consumers import the packaged
  `priv/acceptance_evidence/evidence.json` using their existing offline release
  migration entry point; no distributed RPC or duplicate application boot is
  required. Consumers without browser acceptance are unchanged.

## 0.4.39

- Reject common framework, configuration, secret-file, database-dump, and
  archive probes in nginx before they reach the application.

## 0.4.38

- Add a host-managed deployment lifecycle state-file transport for releases
  with distribution disabled. This corrects the lifecycle extension introduced
  in 0.4.34-era consumers that otherwise attempted release RPC before blue/green
  cutover.

## 0.4.37

- Instrument incremental acceptance-test phases in GitLab CI.
