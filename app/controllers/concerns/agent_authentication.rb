# frozen_string_literal: true

# Autenticazione degli agent di server monitoring (bearer = enrollment token universale org-scoped,
# prefisso cyi_s_). Pinna SOLO Current.organization (niente project: gli host non sono per-progetto).
# Concern separato da TokenAuthentication, che è legato a Projects::Token e all'anti-BOLA :project_id.
module AgentAuthentication
  extend ActiveSupport::Concern
  include OrganizationSuspension

  private

  # CYRA-469 — il codice di accesso con cui l'agent si è autenticato in QUESTA richiesta, o nil se è
  # entrato con la credenziale per-host. RegisterHost lo lega all'host alla prima registrazione.
  def current_enrollment_token = @server_enrollment_token

  def authenticate_agent!
    presented = presented_agent_token
    host_token = Servers::HostToken.active.includes(:host).find_by(token_digest: digest(presented))
    if host_token
      return render_error("R403-SERVER-002", "Host revocato", status: :forbidden) if host_token.host.revoked?

      Current.organization = host_token.host.organization
      Current.server_host = host_token.host
      # CYRA-722 — organizzazione sospesa: le sonde smettono di essere ascoltate come tutto il resto.
      return if reject_suspended_organization!

      host_token.update_column(:last_used_at, Time.current) if host_token.stale_usage?
      return
    end

    token = Servers::EnrollmentToken.active.find_by(token_digest: digest(presented))
    if token.nil?
      # CYRA-245 — «la tua credenziale non vale più» non è «non ti conosco»: sono due cose diverse e
      # il 401 unico le confondeva, così una sonda a cui era stata tolta la credenziale continuava a
      # ripresentarla all'infinito senza sapere che doveva invece ripartire dal codice della flotta.
      # Il digest esiste soltanto se la credenziale è stata emessa a quella macchina: nessuna
      # informazione nuova a chi non ce l'ha già.
      if Servers::HostToken.exists?(token_digest: digest(presented))
        return render_error("R401-SERVER-002", "Credenziale della macchina non più valida: ripresentati con l'enrollment token",
                            status: :unauthorized)
      end

      return render_error("R401-SERVER-001", "Enrollment token mancante o non valido", status: :unauthorized)
    end

    Current.organization = token.organization
    @server_enrollment_token = token

    return if reject_suspended_organization!

    # Debounce: aggiorna last_used_at solo se stantio, senza callback (hot path).
    token.update_column(:last_used_at, Time.current) if token.stale_usage?
  end

  def presented_agent_token
    header = request.authorization
    return "" unless header&.start_with?("Bearer ")

    header.delete_prefix("Bearer ").strip
  end

  def digest(value) = Digest::SHA256.hexdigest(value.to_s)
end
