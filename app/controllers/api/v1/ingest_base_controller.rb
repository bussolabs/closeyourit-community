# frozen_string_literal: true

module Api
  module V1
    # Base dei canali di SOLA SCRITTURA (ingest) dell'API v1: events, logs, metrics, pageviews, replays.
    #
    # A differenza di Api::V1::BaseController (bearer-only, per le read: error_groups/metric_groups/…),
    # accetta DUE credenziali (CYRA-108):
    #   - il bearer secret server-side (Authorization: Bearer cyi_…), a piena potenza (scope del token);
    #   - la DSN public key non-segreta (X-Sentry-Auth o ?sentry_key=), usata dagli SDK browser
    #     (closeyourit-js) — così log/metriche/visite/replay funzionano dal browser come già gli errori
    #     via /api/:project_id/{envelope,store}, senza esporre un segreto.
    #
    # La public key resta confinata all'ingest e NON apre alcuna API di lettura: le read usano
    # Api::V1::BaseController (authenticate_token! risolve SOLO il bearer segreto → una public key su
    # una rotta di lettura riceve 401). L'anti-BOLA (:project_id del path == progetto del token) e lo
    # scope :ingest sono centralizzati qui: valgono per ogni canale, con qualsiasi credenziale.
    class IngestBaseController < Api::V1::BaseController
      # Per resolve_dsn_token / sentry_key (risoluzione della DSN public key). authenticate_ingest!
      # del concern NON viene usato: qui l'autenticazione unifica bearer + public key.
      include IngestAuthentication

      skip_before_action :authenticate_token!
      before_action :authenticate_ingest_credential!
      before_action :enforce_origin_allowlist! # difesa browser aggiuntiva (CYRA-109), dopo l'auth
      before_action -> { require_scope!(:ingest) }
      before_action :mark_ingest_authorized!

      private

      # Bearer segreto (se presente) altrimenti DSN public key. Nessuna credenziale valida → 401.
      # Poi enforce_project_scope! (TokenAuthentication): :project_id del path deve combaciare col
      # progetto del token, con qualunque credenziale (anti-BOLA centralizzato).
      def authenticate_ingest_credential!
        token = resolve_ingest_token
        return unauthorized_ingest if token.nil? || token.revoked?

        Current.api_token = token
        Current.project = token.project
        Current.organization = token.project.organization
        # CYRA-722 — qui l'autenticazione è scritta a parte (unifica bearer e DSN) e non passa per le
        # concern: il controllo sulla sospensione va ripetuto, o l'ingest resterebbe l'unico canale
        # aperto a un'organizzazione fermata.
        return if reject_suspended_organization!

        token.update_column(:last_used_at, Time.current) if token.stale_usage?

        enforce_project_scope!
      end

      # Il bearer segreto ha la precedenza; in sua assenza si prova la DSN public key. Entrambi i
      # resolver filtrano già i token attivi (revoked_at: nil).
      def resolve_ingest_token
        resolve_bearer_token || resolve_dsn_token
      end

      def unauthorized_ingest
        render_error("R401-AUTH-001", "Credenziale di ingest mancante o non valida", status: :unauthorized)
      end
    end
  end
end
