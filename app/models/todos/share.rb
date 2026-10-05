# frozen_string_literal: true

module Todos
  # Condivisione in sola lettura di una lista con un membro dell'organizzazione (il destinatario).
  # Il destinatario dev'essere membro dell'org della lista (anti-leak cross-tenant) e non il
  # proprietario stesso. Unicità (list, account): niente doppioni.
  class Share < ApplicationRecord
    belongs_to :list, class_name: "Todos::List", inverse_of: :shares
    belongs_to :account, class_name: "Accounts::Account"

    validates :account_id, uniqueness: { scope: :list_id }
    validate :recipient_is_org_member
    validate :recipient_is_human
    validate :not_sharing_with_owner

    private

    # CYRA-556: il destinatario è una persona. Le utenze dei programmi non aprono mai le pagine —
    # una lista condivisa con loro resterebbe lì senza che nessuno la legga. Il filtro sul form non
    # basta: qui passa qualunque canale, anche un id scritto a mano nella richiesta.
    def recipient_is_human
      return if account.blank?

      errors.add(:account, :is_service) if account.service?
    end

    # Isolamento tenant: il destinatario dev'essere membro dell'org della lista. Gli account sono
    # N:M con le org via Connections::Membership (come reporter/assignee dei ticket).
    def recipient_is_org_member
      return if account.blank? || list.blank?

      member = Connections::Membership.exists?(account_id: account_id, organization_id: list.organization_id)
      errors.add(:account, :not_member) unless member
    end

    # Non ha senso condividere una lista con sé stessi (il proprietario la vede già).
    def not_sharing_with_owner
      return if list.blank?

      errors.add(:account, :is_owner) if account_id == list.account_id
    end
  end
end
