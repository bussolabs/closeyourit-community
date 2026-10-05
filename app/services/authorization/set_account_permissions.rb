# frozen_string_literal: true

module Authorization
  # Imposta gli override personali di un account in un'org (allow/deny per chiave). Reconcile completo:
  # le chiavi non più presenti vengono rimosse. allow ha precedenza se una chiave è in entrambe le liste.
  # Scarta chiavi fuori dal Catalog. Transazionale, audit sync. Gli override BATTONO i ruoli nel Resolver.
  class SetAccountPermissions < ApplicationService
    def initialize(organization:, account:, allow_keys: [], deny_keys: [], actor: nil, true_actor: nil)
      @organization = organization
      @account = account
      @allow = sanitize(allow_keys)
      @deny = sanitize(deny_keys) - @allow
      @actor = actor
      @true_actor = true_actor
    end

    def call
      # Removing a denial restores inherited authority and requires the same grant permission.
      removed_denials = @account.account_permissions.where(organization_id: @organization.id, effect: :deny)
        .pluck(:permission_key) - @deny
      barrier = grant_barrier(@allow | removed_denials)
      return Result.err(barrier) if barrier

      desired = {}
      @allow.each { |k| desired[k] = "allow" }
      @deny.each { |k| desired[k] = "deny" }

      ActiveRecord::Base.transaction do
        scope = @account.account_permissions.where(organization_id: @organization.id)
        existing = scope.each_with_object({}) { |ap, h| h[ap.permission_key] = ap }

        (existing.keys - desired.keys).each { |k| existing[k].destroy! }
        desired.each do |key, effect|
          ap = existing[key]
          if ap.nil?
            # organization: (oggetto, non _id) → belongs_to già risolto in memoria: senza, ogni create!
            # ricarica organizations per la presence validation (stessa fingerprint per N chiavi = N+1).
            @account.account_permissions.create!(organization: @organization,
                                                 permission_key: key, effect: effect)
          elsif ap.effect != effect
            ap.update!(effect: effect)
          end
        end

        Authorization::RecordChange.call(
          organization: @organization, action: "personal_override_set",
          actor: @actor, true_actor: @true_actor,
          data: { account: @account.name, allow: @allow, deny: @deny }
        )
      end
      Result.ok(@account)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-ACCESS-006", details: e.record.errors.to_hash))
    end

    private

    # AppError R403-ACCESS-001 se `keys` contiene chiavi che l'attore non può concedere, altrimenti nil.
    def grant_barrier(keys)
      forbidden = Authorization::GrantGuard.forbidden_keys(actor: @actor, organization: @organization, keys: keys)
      return if forbidden.empty?

      AppError.new("Non puoi concedere permessi o ruoli che non possiedi",
                   code: "R403-ACCESS-001", status: :forbidden, details: { forbidden_keys: forbidden })
    end

    def sanitize(keys)
      Array(keys).reject(&:blank?).select { |k| Authorization::Catalog.valid?(k) }.uniq
    end
  end
end
