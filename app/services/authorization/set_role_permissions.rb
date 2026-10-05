# frozen_string_literal: true

module Authorization
  # Imposta le chiavi-permesso di un ruolo (sostituisce l'insieme, idempotente). Scarta le chiavi
  # fuori dal Catalog. Transazionale, audit sync. Modifica = propaga LIVE ai portatori. Result pattern.
  class SetRolePermissions < ApplicationService
    # known_current: le chiavi già presenti sul ruolo, se il chiamante le conosce (es. ruolo appena
    # creato → []). Quando fornito, si salta la pluck per-ruolo (evita N+1 quando il servizio è
    # invocato in loop su più ruoli freschi, es. InstallDefaultRoles).
    def initialize(role:, permission_keys:, actor: nil, true_actor: nil, known_current: nil, enforce_grant: true)
      @role = role
      @organization = role.organization
      @keys = Array(permission_keys).reject(&:blank?).select { |k| Authorization::Catalog.valid?(k) }.uniq
      @actor = actor
      @true_actor = true_actor
      @known_current = known_current
      # enforce_grant: false → SEED di sistema (InstallDefaultRoles): salta il subset-check ma tiene l'actor
      # per l'audit. I ruoli default portano chiavi che il nuovo owner non possiede ancora; senza questo,
      # il guard le bloccherebbe (+ N+1 nel loop dei 4 ruoli) rompendo la creazione dell'org.
      @enforce_grant = enforce_grant
    end

    def call
      # Chiavi CONCESSE = quelle aggiunte (rimuovere è sempre lecito). Guard anti-escalation PRIMA della
      # transazione (fail-fast, nessuna mutazione): un attore non-owner non può mettere nel ruolo chiavi
      # che non possiede né chiavi scoped (che il ruolo concederebbe org-wide).
      current = @known_current || @role.role_permissions.pluck(:permission_key)
      add = @keys - current
      if @enforce_grant
        barrier = grant_barrier(add)
        return Result.err(barrier) if barrier
      end

      ActiveRecord::Base.transaction do
        remove = current - @keys
        @role.role_permissions.where(permission_key: remove).destroy_all if remove.any?
        add.each { |k| @role.role_permissions.create!(permission_key: k) }
        audit("permission_granted", add)
        audit("permission_revoked", remove)
      end
      Result.ok(@role)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-ACCESS-004", details: e.record.errors.to_hash))
    end

    private

    # AppError R403-ACCESS-001 se `keys` contiene chiavi che l'attore non può concedere, altrimenti nil.
    def grant_barrier(keys)
      forbidden = Authorization::GrantGuard.forbidden_keys(actor: @actor, organization: @organization, keys: keys)
      return if forbidden.empty?

      AppError.new("Non puoi concedere permessi o ruoli che non possiedi",
                   code: "R403-ACCESS-001", status: :forbidden, details: { forbidden_keys: forbidden })
    end

    def audit(action, keys)
      return if keys.empty?

      Authorization::RecordChange.call(
        organization: @organization, action: action,
        actor: @actor, true_actor: @true_actor,
        data: { role: @role.name, keys: keys }
      )
    end
  end
end
