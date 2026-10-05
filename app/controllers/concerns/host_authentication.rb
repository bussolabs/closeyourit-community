# frozen_string_literal: true

module HostAuthentication
  extend ActiveSupport::Concern
  include OrganizationSuspension

  private

  def authenticate_host!
    presented = request.authorization&.delete_prefix("Bearer ")&.strip
    token = Servers::HostToken.active.find_by(token_digest: Digest::SHA256.hexdigest(presented.to_s))
    return render_error("R401-SERVER-005", "Missing or invalid host token", status: :unauthorized) unless token && !token.host.revoked?

    Current.organization = token.host.organization
    Current.server_host = token.host
    # CYRA-722 — organizzazione sospesa: nemmeno le azioni sui server della flotta vengono servite.
    return if reject_suspended_organization!

    token.update_column(:last_used_at, Time.current) if token.stale_usage?
  end
end
