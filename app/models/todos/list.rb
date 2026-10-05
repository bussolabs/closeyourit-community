# frozen_string_literal: true

module Todos
  # Lista di todo personale, per-organizzazione (stesso scoping di SavedView): possesso
  # di un account dentro un'org. Privata di default; può essere condivisa in sola lettura con membri
  # scelti dell'org via Todos::Share. Lo scope .for(account, organization) è anche anti-BOLA per
  # find/destroy nelle azioni di modifica.
  class List < ApplicationRecord
    belongs_to :account, class_name: "Accounts::Account"
    belongs_to :organization, class_name: "Organizations::Organization"

    has_many :items, -> { ordered }, class_name: "Todos::Item", inverse_of: :list, dependent: :destroy
    has_many :shares, class_name: "Todos::Share", inverse_of: :list, dependent: :destroy
    has_many :shared_accounts, through: :shares, source: :account

    normalizes :name, with: ->(value) { value.to_s.strip }
    normalizes :color, with: ->(value) { value.to_s.strip.presence }

    validates :name, presence: true, uniqueness: { scope: %i[account_id organization_id] }

    scope :ordered, -> { order(:position, :name) }

    # Liste dell'account nell'org (possedute). Anti-BOLA per find/destroy.
    def self.for(account:, organization:)
      where(account_id: account.id, organization_id: organization.id)
    end

    # Liste condivise CON l'account dato (destinatario di una Todos::Share).
    scope :shared_with, ->(account) { joins(:shares).where(todos_shares: { account_id: account.id }) }

    def items_count = items.size

    def done_count = items.count(&:done?)
  end
end
