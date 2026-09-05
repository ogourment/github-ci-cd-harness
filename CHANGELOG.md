# Changelog

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
