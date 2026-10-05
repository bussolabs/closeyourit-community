# frozen_string_literal: true

# Autenticazione a token bearer per l'API (senza sessione). Risolve il token dal digest e pinna
# Current.organization + Current.project (account resta nil) → tutto lo scoping org-based vale invariato.
module TokenAuthentication
  extend ActiveSupport::Concern
  include OrganizationSuspension

  private

  def authenticate_token!
    token = resolve_bearer_token
    # revoked?/expired? sono ridondanti col filtro dello scope .active in resolve_bearer_token: restano
    # come difesa in profondità, così un domani in cui .active cambiasse non riaprirebbe l'ingest a
    # una credenziale revocata o scaduta senza che nessuno se ne accorga (CYRA-716).
    if token.nil? || token.revoked? || token.expired?
      return render_error("R401-AUTH-001", "Token API mancante o non valido", status: :unauthorized)
    end

    Current.api_token = token
    Current.project = token.project
    Current.organization = token.project.organization

    # CYRA-722 — organizzazione sospesa: il token è valido ma non vale più niente. Prima di segnare
    # l'uso, che direbbe il falso su una credenziale a cui non è stato servito nulla.
    return if reject_suspended_organization!

    # Debounce: aggiorna last_used_at solo se stantio, senza callback (hot path).
    token.update_column(:last_used_at, Time.current) if token.stale_usage?

    enforce_project_scope!
  end

  # Anti-BOLA centralizzato: se la rotta porta :project_id (ingest per-progetto), DEVE combaciare col
  # progetto del token — così nessun controller può dimenticarsene. Le rotte token-bearer senza
  # :project_id (read API: error_groups/metric_groups/log_entries, types lookup) sono esenti. Uso
  # request.path_parameters (router, non parsa il body) → nessun side-effect sul corpo della richiesta.
  def enforce_project_scope!
    scoped_id = request.path_parameters[:project_id]
    return if scoped_id.blank?
    return if scoped_id.to_s == Current.project.id.to_s

    render_project_scope_mismatch
  end

  # Risposta di default al mismatch (bare 404). I controller con un contratto envelope di dominio
  # proprio (es. logs → R404-LOG-001) sovrascrivono questo metodo.
  def render_project_scope_mismatch
    head :not_found
  end

  def resolve_bearer_token
    header = request.authorization
    return nil unless header&.start_with?("Bearer ")

    presented = header.delete_prefix("Bearer ").strip
    return nil if presented.blank?

    Projects::Token.active.find_by(token_digest: Digest::SHA256.hexdigest(presented))
  end

  # Enforce dello scope del token (rules: ingest vs read). Gira come before_action DOPO
  # authenticate_token! (Current.api_token è già pinnato): un token privo dello scope richiesto
  # → 403 R403-AUTH-002. La lettura della telemetria (error_groups/metric_groups/log_entries e le
  # altre read bearer) richiede :read; gli endpoint d'ingest richiedono :ingest. Così un token
  # ingest-only esfiltrato NON legge l'intero catalogo errori/metriche/log del progetto.
  # Vedi CYRA-37 / decisions/2026-07-09-cyi-token-server-only.
  def require_scope!(scope)
    return if Current.api_token&.scope?(scope)

    render_error("R403-AUTH-002", "Il token non dispone dello scope richiesto (#{scope})", status: :forbidden)
  end
end
