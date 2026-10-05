# Pinned installation observations

The Member guide reads only this local snapshot. It never fetches a registry, schema or certification manifest during a request. These nine observations currently claim **implemented**, including the four PHP partitions from one candidate run; a passing individual signal does not promote the overall claim.

Refresh from a reviewed, committed Docs checkout with:

```sh
bundle exec ruby script/installation/vendor_catalog.rb /absolute/path/to/closeyourit-docs
```

The script projects the canonical schema, verifies the entire candidate with the application validator, then atomically replaces each file with `LOCK.json` last. A concurrent mixed-version reader returns unavailable. Review and commit `observations.json`, `schema.json` and `LOCK.json` **together**, and deploy the immutable application revision through the normal workflow; do not hot-edit a running instance. The source revision and each file SHA-256 are part of the pin. Validate the canonical Docs importer/verifier before accepting new observations; importing does not create evidence or change historical claims.

The 5 MiB input limit and 10,000 observations are conservative local parsing ceilings, not storage or certification targets. The guide caps its response at 1 MiB, its observation selector at 100 plus the selected value, and its visible project selector at 200 plus the selected project. History is paginated. A broken pin, invalid schema/reference, credential pattern, duplicate identity or overstated claim returns 503 rather than an empty or promoted catalog.

Receipt checks use exact project, environment and release, plus an event ID or an actual trace/span pair selected by the observation. They compare persisted server arrival time, never SDK occurrence time or correlated errors. Default window: 15 minutes. Explicit windows require both UTC bounds, at most 24 hours, ending no later than now. SQL runs under a restored 250 ms statement timeout and projects only arrival metadata; timeout is unavailable, never pending or received. Receipts are bounded to 4 KiB and return microsecond UTC timestamps.

Public DSNs require `tokens.manage` and visibility of the selected project. Selection uses an already existing, active ingest-scoped token, optionally matching the requested environment. Private bearer credentials are never loaded or rendered. PHP requires both runtime bearer and public DSN for the same project. Local candidates must be installed from the exact reviewed artifact, not a registry package sharing its version.
