# CloseYourIt

Open source bug tracking and observability: errors, tickets, uptime, performance and logs in one
workspace you run on your own server. The same identifiers cross the whole flow, so when production
breaks the evidence stays next to the decision until the fix is verified.

## Install

On a Linux server with 4 GB of memory and a domain pointing to it:

```bash
curl -fsSL https://get.closeyour.it | sudo bash
```

The script checks Docker, asks for the domain, an email for the HTTPS certificate and your SMTP
server, generates every secret key, and starts the app, a worker, PostgreSQL and Caddy with HTTPS and
a nightly backup. Then:

| Command | Does |
|---|---|
| `closeyourit update` | backs up, installs the new version, goes back by itself if it does not answer |
| `closeyourit backup` / `restore <file>` | database copies (the last 7 are kept) |
| `closeyourit enable ingest` | queues supported telemetry after the app has authorized it; clients retry when authorization is unavailable |
| `closeyourit doctor` | checks disk, certificate, version and backups |

Full guide: https://closeyour.it/docs

Before upgrading, read [Security and upgrade requirements](SECURITY-UPGRADE.md), including
GitHub integration settings, ingest rollout order and client retry behavior.

## What is inside

- **Error monitoring** — deduplicated groups with stacktrace, breadcrumbs and tags; regressions reopen
  the group; compatible Sentry SDKs connect through the project DSN.
- **Tickets** — evidence-first bug reports (given / when / then / expected), kanban, roadmap,
  unified timeline, mentions, saved views.
- **Uptime** — HTTP monitors with SLA windows and opt-in public status pages.
- **Performance** — slow queries and methods turned into verdicts such as N+1 and slow requests.
- **Logs** — structured logs correlated with errors and metrics by `trace_id`.
- **Alerting**, knowledge base, access control by action, audit trail.

SDKs: Ruby, JavaScript, Dart/Flutter, Python. CLI: `cyi`.

## AI, optional

Assistant, ticket analysis, dictation and smart search turn on when an AI service is connected in
**Administration → AI settings**: any OpenAI-compatible provider (including a model you host) or a
CloseYourIt AI key, in preview. Without it everything else works the same.

## Development

Rails 8 · PostgreSQL with pgvector · Hotwire · Solid Queue.

```bash
bin/setup
bin/dev            # http://localhost:3011
bundle exec rspec
```

## License and contributions

- Server: AGPL-3.0 (`LICENSE`). SDKs and CLI: MIT, in their own repositories:
  [JavaScript](https://github.com/bussolabs/closeyourit-js-community),
  [Ruby](https://github.com/bussolabs/closeyourit-ruby-community),
  [Python](https://github.com/bussolabs/closeyourit-python-community),
  [Dart and Flutter](https://github.com/bussolabs/closeyourit-dart-community),
  [CLI](https://github.com/bussolabs/closeyourit-cli-community).
- Pull requests are welcome. On your first one the CLA bot asks you to accept `CLA.md`.
- This repository is a copy published at every release. Development happens in a private repository;
  accepted pull requests are applied there with your authorship and come back with the next release.
- Fork pull requests do not execute code on the project's managed runners. Maintainers review
  contributions before importing them into the development repository for validation.
