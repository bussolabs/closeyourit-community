# frozen_string_literal: true

require "set"

module Authorization
  # Guard anti privilege-escalation: "non puoi concedere ciò che non possiedi". Condiviso dai service
  # che assegnano permessi/ruoli (SetRolePermissions/SetAccountPermissions/SetAccountRoles + Teams::
  # SetTeamRoles). Ritorna le chiavi che `actor` NON può concedere in `organization` — vuoto = via libera.
  class GrantGuard
    # - actor nil (seed/InstallDefaults senza attore) → nessun vincolo.
    # - owner/god (VisibleScope.unscoped?) → nessun vincolo.
    # - chiave org-level → vietata se non nei permessi effettivi dell'attore.
    # - chiave scoped → SEMPRE vietata a un non-owner: un Role/override org-wide la concederebbe
    #   oltre lo scope per-progetto che l'attore possiede → solo owner/god può metterla in un bundle.
    def self.forbidden_keys(actor:, organization:, keys:)
      keys = Array(keys).uniq
      return [] if keys.empty? || actor.nil?
      return [] if Authorization::VisibleScope.unscoped?(account: actor, organization: organization)

      snapshot = Authorization::AccessMatrix.call(account: actor, organization: organization, projects: [])
      scoped = Authorization::AccessMatrix::SCOPED_KEYS.to_set
      keys.select { |key| scoped.include?(key) || !snapshot.org_keys.include?(key) }
    end
  end
end
