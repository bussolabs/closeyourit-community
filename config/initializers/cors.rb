# frozen_string_literal: true

# CORS limitato ai SOLI endpoint di ingest: /api/v1/projects/:id/{events,metrics,logs,pageviews,replays}.
# Gli SDK browser (closeyourit-js) inviano eventi/metriche/log/visite/replay da origini arbitrarie —
# i siti dei progetti monitorati — quindi il browser esegue un preflight OPTIONS che, senza CORS,
# fallirebbe.
#
# origins "*" è sicuro qui perché l'ingest si autentica per-progetto tramite bearer token
# nell'header Authorization (Bearer cyi_…) OPPURE la DSN public key non-segreta (header X-Sentry-Auth
# o query ?sentry_key=, CYRA-108) e NON usa cookie/sessioni: con credentials: false nessuna risorsa
# autenticata via cookie è raggiungibile cross-origin. La public key apre solo l'ingest, mai le read.
# Il resto dell'app (web/member/valhalla/cli) resta volutamente senza header CORS.
#
# La restrizione di provenienza (origin allowlist per-progetto, CYRA-109) NON vive qui ma è enforced
# server-side nel gateway ingest (IngestAuthentication#enforce_origin_allowlist! → 403 R403-INGEST-002):
# CORS resta permissivo di proposito così il browser riceve comunque l'errore 403 chiaro invece di un
# fallimento CORS opaco. L'allowlist è una difesa browser AGGIUNTIVA, mai un'autenticazione.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"

    resource %r{\A/api/[^/]+/(?:envelope|store|minidump)/?\z},
             headers: %w[Authorization Content-Type Content-Encoding X-Sentry-Auth],
             expose: %w[Retry-After X-Sentry-Rate-Limits X-CloseYourIt-Ignored-Items X-CloseYourIt-Attachment-Results],
             methods: %i[post options],
             credentials: false,
             max_age: 3600

    resource "/api/v1/projects/*",
             headers: %w[Authorization Content-Type X-Sentry-Auth],
             methods: %i[post options],
             credentials: false,
             max_age: 3600
  end
end
