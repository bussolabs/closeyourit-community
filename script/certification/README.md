# Real SDK certification backend

These hooks serve the sibling `closeyourit-labs/bin/certify-stack` runner (CYRA-982).
They are test tools, not HTTP endpoints, deployment commands or development seed tasks.
The ordinary Rails test adapter remains unchanged.

Every process requires `RAILS_ENV=test`, a 16-character lowercase hexadecimal
`CERTIFICATION_RUN_ID`, and `TEST_SLOT=_cert_<run_id>`. Database URL overrides,
remote PostgreSQL hosts, another slot and parallel-test suffixes are refused before
Rails boots. Resolved database names are checked again after configuration loads.

Prepare a **new** slot once, from this repository:

```sh
RAILS_ENV=test TEST_SLOT=_cert_9820000000000001 \
  CERTIFICATION_RUN_ID=9820000000000001 \
  mise exec -- ruby -S bundle exec ruby script/certification/prepare.rb
```

Preparation refuses existing PostgreSQL or SQLite databases. It does not reset or
drop a database and does not run seeds. Use a fresh run ID for another execution.
It applies pending migrations to the new slot without rewriting repository schema files.
If workstation policy blocks schema initialization, an operator must run this
command; do not disable the guard or redirect it to an existing environment.

The runner starts `server.rb` bound to `127.0.0.1:CERTIFICATION_PORT` and `worker.rb`
with real Solid Queue processing. Only `ingest` and `default` queues run; recurring
jobs stay disabled. Rack::Attack uses a process-local memory store so the real rate
limits remain observable despite the ordinary test environment's null cache.
Runtime credentials and configuration belong in process memory,
never a `.env` file. The runner supplies the actual Git SHA for `/version`.

`bootstrap.rb` takes `{ "run_id": "...", "action": "create|inspect|retention|cleanup" }`
on stdin and returns JSON exclusively through an inherited anonymous pipe on fd 3.
The `create` action issues short-lived credentials for two isolated projects using
the production token service. There are separate ingest-only and read-only tokens.
The `inspect` action returns sanitized database counts and Solid Queue completion
evidence and bounded rejection-code counters, never raw logs. `retention` runs the
real prune jobs under an advanced test clock after the worker has stopped; the runner
must preserve positive delivery evidence before testing expiration. `cleanup` revokes
only this run's tokens and retains database evidence;
it does not drop databases or erase observations.

Telemetry is read through normal authenticated APIs, not a test dump endpoint:

- `GET /api/v1/error_groups/:id/events`
- `GET /api/v1/metric_groups/:id/samples`
- `GET /api/v1/log_entries`
- `GET /api/v1/projects/:id/usages`

The new collections require a project bearer with `read` scope. Detail responses
contain persisted payloads, including their existing ingestion scrubbing. They
are paginated with `page` and `per`, default 10 and maximum 200 records.
