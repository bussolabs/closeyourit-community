# Security and upgrade requirements

## GitHub integration

Connecting a GitHub installation requires proof of the signed-in user's authority through
GitHub OAuth. Configure `GH_APP_CLIENT_ID`, `GH_APP_CLIENT_SECRET` and the callback
`/member/integrations/github/callback` on your application host through your secret manager.
The GitHub App needs organization Members
read permission to verify an active organization administrator. Missing configuration or
failed verification prevents linking; an installation ID alone grants no authority.

## Ingest gateway and NATS

Deploy Rails with the admission-header support before upgrading the gateway. Only the
configured Rails upstream can authorize durable fallback. A client-supplied admission
header has no effect. Network failures, missing upstream authorization and HTTP 429 are
returned to the client for retry; the gateway is unready when Rails authorization is
unavailable. Raw Sentry envelopes and minidumps are never queued by this fallback.
Clients must retain and retry telemetry when required, respecting `Retry-After`.

New NATS streams default to **250,000 messages**, alongside byte and age limits.
`QUEUE_MAX_MESSAGES` accepts a positive integer. Without an override, existing finite
limits are preserved; explicit increases are accepted. **No reduction to 10,000 is required.**
An unlimited stream or an explicit reduction requires a controlled maintenance window:
pause publishers, drain or safely export the excess backlog, apply the chosen finite
limit, then resume. Startup refuses these transitions instead of changing the backlog.

The cap is shared across projects. At 600 queued messages per minute without delivery,
250,000 slots last 6 hours, 56 minutes and 40 seconds, unless byte or age limits are reached
first. Size overrides against broker memory. Local capacity fixtures do not establish
production throughput or peak memory use.

## Automator and clients

Upgrade the automator, its guardrails and skills bundle together. The Linux host requires
working bubblewrap and installed gate dependencies. Local gates have no external network;
checks requiring remote services belong in CI. Release authority must come from the
assigned lease. Missing authority or an unavailable sandbox stops execution.

Flutter sessions without a matching issuer require a fresh login. Unbound legacy support
drafts are discarded. Creating a new analytics share link invalidates prior active links
for the project.

## Resource limits

- Sentry envelope: at most 100 items and 50 events.
- Dataset images: at most 6, checked before download.
- Uptime response: 2 MiB, within the monitor timeout. Webhook response: 64 KiB / 8 seconds.
- Replay session: 120 chunks, 100,000 events, 20 MiB compressed and 40 MiB decompressed.
  Each chunk is limited to 3 MiB compressed and 2 MiB decompressed. Historical sessions
  above the read limit are rejected; new excess chunks are dropped.

These controls reduce known attack paths. They do not guarantee the absence of other
vulnerabilities. Report suspected vulnerabilities through [SECURITY.md](SECURITY.md).
