# frozen_string_literal: true

# Autenticazione dell'ingest Sentry via DSN public key (NON segreta, viaggia negli SDK). La chiave
# arriva dall'header X-Sentry-Auth (sentry_key=...) o dal query param ?sentry_key=. Pinna org+project
# su Current e verifica che il token appartenga al :project_id del path (anti-confusione/BOLA).
module IngestAuthentication
  extend ActiveSupport::Concern
  include OrganizationSuspension

  private

  def authenticate_ingest!
    token = resolve_dsn_token
    # expired? è ridondante col filtro .active di resolve_dsn_token (difesa in profondità, CYRA-716):
    # una DSN scaduta non autentica, esattamente come una revocata.
    if token.nil? || token.expired? || !ingest_project_matches?(token)
      return render_error("R401-AUTH-001", "DSN mancante o non valida", status: :unauthorized)
    end

    Current.api_token = token
    Current.project = token.project
    Current.organization = token.project.organization

    # CYRA-722 — la DSN pubblica non è un'eccezione: un'organizzazione sospesa non riceve dati da
    # nessun canale, nemmeno da quello che gli SDK browser portano in chiaro.
    return if reject_suspended_organization!

    unless token.scope?(:ingest)
      Rails.logger.warn({ event: "auth.unauthorized", project_id: token.project_id, reason: "ingest_scope_required" }.to_json)
      return render_error("R403-AUTH-001", "Ingest scope required", status: :forbidden)
    end

    token.update_column(:last_used_at, Time.current) if token.stale_usage?
  end

  # Difesa browser AGGIUNTIVA del public ingest (CYRA-109), MAI un'autenticazione. Se il progetto ha
  # dichiarato un'allowlist di origini e la richiesta porta un header Origin (= browser) non elencato,
  # rifiuta con 403 e un errore chiaro. Le richieste SENZA Origin (client non-browser: SDK server, CI)
  # e la lista vuota non vengono mai bloccate. Da montare come before_action DOPO l'autenticazione
  # (Current.project pinnato). L'enforcement vive qui, non in CORS (che resta permissivo per consegnare
  # comunque l'errore al browser).
  def enforce_origin_allowlist!
    origin = request.headers["Origin"].presence
    return if origin.nil?
    return if Current.project.blank?
    return if Current.project.origin_allowed?(origin)

    render_error("R403-INGEST-002", "Origine non consentita per questo progetto", status: :forbidden)
  end

  # Emitted only after all admission callbacks succeed; never trust a request-side copy.
  def mark_ingest_authorized!
    response.set_header("X-CloseYourIt-Ingest-Authorized", "true")
  end

  def resolve_dsn_token
    key = sentry_key
    key && Projects::Token.active.find_by(public_key: key)
  end

  def ingest_project_matches?(token)
    identifier = request.path_parameters[:project_id].to_s
    identifier == token.project_id.to_s || identifier == token.project.sentry_project_id.to_s
  end

  def sentry_key
    query_key = request.query_parameters["sentry_key"].presence
    return nil if query_key && header_key && query_key != header_key

    header_key || query_key
  end

  def header_key
    raw = request.headers["X-Sentry-Auth"] || request.authorization
    raw && raw[/sentry_key=([0-9a-f]+)/i, 1]
  end
end
