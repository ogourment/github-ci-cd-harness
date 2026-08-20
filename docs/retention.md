# Phoenix retention policies

The harness applies the same three-tier shape to backups and releases:

- keep the newest `N` items;
- then keep one item per UTC day through a configured age;
- then keep one item per ISO week through a configured age.

Backups use `backup_keep_recent`, `backup_keep_daily_days`, and
`backup_keep_weekly_days`. Releases use `deploy_keep_recent`,
`deploy_keep_daily_days`, and `deploy_keep_weekly_days`.

The release defaults are `5 / 7 / 14`. They are compatibility defaults, not a
capacity recommendation. Every infrastructure repository should declare its
reviewed values explicitly.

## Capacity contract

Retention is a physical-host budget, not an application-local choice. Before
selecting values, inventory every application and unmanaged workload sharing
the filesystem. Budget at least:

```text
steady backup bytes
  = sum(app snapshot upper bound * app retained snapshot upper bound)

steady release bytes
  = sum(app release upper bound * app retained release upper bound)

required free headroom
  >= largest next snapshot + largest next release extraction + operating margin
```

Use measured upper bounds with growth margin, not current averages. A practical
minimum operating margin is 20% of the filesystem unless the owning infra repo
documents a stronger measured constraint. The retained-item upper bound is not
simply the sum of the three settings because recent items may overlap daily and
weekly buckets; using the sum is a safe sizing approximation.

For a shared host, the sum of all app allocations must fit while preserving
headroom. A policy that fits one app in isolation is invalid if another app,
legacy tree, CI evidence, journal, or cache can consume that margin.

## Disk-full behavior

Backup pruning runs before and after snapshot creation. Release pruning runs
before artifact staging and after successful cutover. Pre-pruning lets a host
recover policy-excess space before an operation needs temporary working space.

Pre-pruning cannot reclaim items that are still inside policy, cannot manage
another application's tree, and cannot make an oversized host-wide allocation
safe. Host monitoring and capacity review remain required.

## Database and persistent files

When `phoenix_uploads_env_var` or `backup_uploads_env_var` is configured,
uploads are required by default. Set `backup_uploads_required: true`
explicitly in consumer infrastructure so a missing files root cannot silently
produce a database-only recovery point.

Use `backup_exclude_table_data` only for regenerable data. The database schema
is retained, but excluded table contents are intentionally absent after a
restore and are recorded in snapshot metadata.

## Shared and legacy release trees

The deploy helper manages only `{{ app_root }}/releases` and
`deploy_releases_root`. Before adopting the role, identify older deployment
roots and either migrate them into the managed layout or perform an explicitly
reviewed one-time cleanup. Do not add broad filesystem globs to automatic
pruning: current symlink targets and rollback releases must be proven before
deletion.

## Off-host recovery

Host-local retention is not a disaster-recovery copy. Production deployments
should have an encrypted off-host copy, a monitored transfer schedule, and a
tested restore path. Shortening host-local retention is acceptable only when
the required recovery history remains available and verified elsewhere.

Install `priv/operator/phoenix-backup-pull` and its templated user units on an
operator-controlled host. Create one
`~/.config/phoenix-backup-pull/<instance>.env` per application from the example,
then enable `phoenix-backup-pull@<instance>.timer`. The pull model gives the
deployment host no credential capable of deleting the off-host history.
