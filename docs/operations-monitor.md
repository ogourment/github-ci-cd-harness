# Independent Phoenix operations monitoring

Run `priv/operator/phoenix-operations-monitor.py` from a healthy operator host
with a systemd timer every60 seconds. It executes a configured argv probe with
a30 second deadline and submits `alert-event.v1` through A55ist. A separate private
producer token file is required; credentials never go to the monitored VPS.
A55ist owns Telegram routes, provider receipts, incident deduplication and floods.
Do not treat HTTP202 ingestion as proof of Telegram delivery: verify event metadata.

`phoenix-operations-probe.py` runs read-only on the monitored host. Consumer JSON
names filesystem, stable host identity, database, slot ports/color file, app unit,
backup unit/latest directory and maximum backup age. It checks PostgreSQL directly
rather than trusting process liveness. Recent application errors and HTTP5xx are
counted without exporting raw logs. A transport failure is an explicit incident,
never database recovery. No production process is stopped during rehearsal.

Monitor configuration requires `app`, `environment`, `host`, `observer`,
`probe_argv` (including SSH arguments), `token_file`, `a55ist_url`, `state_file`.
Keep configuration, state and credentials private. The receiver must have an exact
application/environment route or explicitly retained legacy global routing.
The monitor persists a pending event before submission and retries the identical
idempotency key after interruption. Only delivery to A55ist clears the pending
entry. Firing/recovery transitions and severity increases are immediate; each
accepted event ID is retained for receiver reconciliation. Disk warning begins
below20% free; critical begins below10%. Failed/stale backups, unavailable database,
application health and application error observations are separate conditions.

The probe JSON uses `observed_at`, `host`, `disk: {free,total}`, boolean `database`,
`application`, `backup`, and integer `application_errors`. `--sample` is a labelled
rehearsal seam; use a separate test identity/state and route to the verified owner.
An independent scheduler heartbeat is still needed to detect a stopped observer.
A55ist downtime cannot produce Telegram through A55ist until it recovers.

`phoenix-release-prune.py` defaults to dry run. Supply each explicit releases
root and every blue/green slot across apps sharing those roots. It always protects
slot targets and the newest two releases, rejects unexpected entries and symlink
roots. The caller must hold all relevant deployment operation locks. Backups,
files and acceptance evidence are outside its scope. Evidence uses the existing
AcceptanceHarness.EvidenceRetention library, retaining database run metadata.

`phoenix-evidence-trim.py --root ROOT --max-bytes BYTES` plans a bounded local
screenshot allocation. Add `--apply` after inspecting the plan. It protects the
newest two captures, retains every manifest and database run record, and trims
older screenshot/thumbnail payloads without generating previews that may then
expire. Use this before the normal thumbnail-retention pass for a small host.
The probe can also verify `maintenance_unit` plus a `maintenance_success_file`;
failed or stale retention is a separate alert condition.

Operations alerts carry an episode correlation key, a direct operator-page URL
and allowlisted observations (HTTP status, app-vs-direct database result, elapsed
time and recent service startup). Recovery retains the initial failure snapshot.
A55ist can link recovery to the same notified incident and send one resolution.
The log error check excludes only an informational readiness 503 with a matching
GET /health request ID; ordinary HTTP 5xx, exceptions and crashes remain counted.
No raw journal text is exported. Older events lack these diagnostic observations.
