# Official Sentry Go exception shape

`go-0.49.0-exception.json` is a privacy-limited projection of an event emitted by
`sentry-go v0.49.0` using `NewClient` and `CaptureException` with
`fmt.Errorf("outer: %w", errors.New("inner"))`. It was generated on 2026-10-05
for CYRA-963. The projection retains the actual exception chain, SDK identity,
event identifier, level and platform; it removes ambient context and absolute
source paths. The frame list preserves the observed function, module and line.

Fixture SHA-256: `eeadf940e94cac7d6dcef809aa398f3d85a0d29fc1ae5f0d40fd67eeb3b7d181`.
The official serializer emits a bare exception array, including its pre-serialized
path. See [the pinned serializer](https://github.com/getsentry/sentry-go/blob/v0.49.0/interfaces.go).
The request regression proves acceptance, canonical storage, chain preservation
and retry deduplication through both Sentry HTTP routes. Malformed mutations are
negative tests; they are not claimed as SDK output.
