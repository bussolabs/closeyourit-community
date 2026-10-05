# frozen_string_literal: true

# Autenticazione del daemon closeyourit-automator con due autorità non intercambiabili: il token
# organization cyi_a_ può soltanto registrare un host; pull e report richiedono il token host cyi_ah_.
module AutomatorAuthentication
  extend ActiveSupport::Concern
  include OrganizationSuspension

  private

  def authenticate_automator_host!
    token = Agents::HostToken.active.includes(host: :organization)
                   .find_by(token_digest: presented_automator_digest)
    return invalid_automator_token if token.nil? || token.host.revoked?
    return unsupported_automator_host unless token.host.supported_platform?

    Current.organization = token.host.organization
    Current.agent_host = token.host
    # CYRA-722 — organizzazione sospesa: il daemon non ritira lavoro e non ne riporta l'esito.
    return if reject_suspended_organization!

    touch_usage(token)
  end

  # Letture di bootstrap compatibili con Automator: prima della registrazione usa cyi_a_, dopo usa
  # cyi_ah_. Le mutazioni autoritative continuano a richiedere esplicitamente il token host.
  def authenticate_automator!
    digest = presented_automator_digest
    host_token = Agents::HostToken.active.includes(host: :organization).find_by(token_digest: digest)
    if host_token && !host_token.host.revoked?
      return unsupported_automator_host unless host_token.host.supported_platform?

      Current.organization = host_token.host.organization
      Current.agent_host = host_token.host
      return if reject_suspended_organization!

      return touch_usage(host_token)
    end

    organization_token = Agents::Token.active.includes(:organization).find_by(token_digest: digest)
    return invalid_automator_token unless organization_token

    Current.organization = organization_token.organization
    return if reject_suspended_organization!

    touch_usage(organization_token)
  end

  # Bootstrap/rotazione host: una credenziale host non può autorizzare nuove registrazioni.
  def authenticate_automator_organization!
    token = Agents::Token.active.find_by(token_digest: presented_automator_digest)
    return invalid_automator_token unless token

    Current.organization = token.organization
    return if reject_suspended_organization!

    touch_usage(token)
  end

  def presented_automator_digest
    header = request.authorization
    return Digest::SHA256.hexdigest("") unless header&.start_with?("Bearer ")

    presented = header.delete_prefix("Bearer ").strip
    Digest::SHA256.hexdigest(presented)
  end

  def touch_usage(token)
    token.update_column(:last_used_at, Time.current) if token.stale_usage?
  end

  def invalid_automator_token
    render_error("R401-AGENT-001", "Token automator mancante o non valido", status: :unauthorized)
  end

  def unsupported_automator_host
    render_error("R403-AGENT-007", "Host automator non supportato: è richiesto Linux", status: :forbidden)
  end
end
