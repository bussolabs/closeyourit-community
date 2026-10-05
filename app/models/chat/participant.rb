# frozen_string_literal: true

module Chat
  # Stato di partecipazione di un account a una conversazione: last_read_at (→ non-letti) e muted_at
  # (notifiche silenziate). Per i DM le 2 righe sono anche l'ACL; per i canali sono create lazy alla
  # prima apertura e servono solo per lo stato. organization_id denormalizzato (come
  # Ticketing::Subscription) blinda lo scoping tenant.
  class Participant < ApplicationRecord
    belongs_to :conversation, class_name: "Chat::Conversation", inverse_of: :participants
    belongs_to :account, class_name: "Accounts::Account"
    belongs_to :organization, class_name: "Organizations::Organization"

    validates :account_id, uniqueness: { scope: :conversation_id }
    validate :organization_matches_conversation
    validate :account_belongs_to_organization

    scope :muted, -> { where.not(muted_at: nil) }
    scope :unmuted, -> { where(muted_at: nil) }

    # Crea la riga di stato se assente (idempotente, race-safe). org denormalizzata dalla conversazione.
    def self.ensure_for(conversation:, account:)
      find_or_create_by(conversation: conversation, account: account) do |participant|
        participant.organization_id = conversation.organization_id
      end
    rescue ActiveRecord::RecordNotUnique
      find_by(conversation: conversation, account: account)
    end

    def muted? = muted_at.present?

    def mark_read!(at: Time.current)
      update!(last_read_at: at)
    end

    private

    def organization_matches_conversation
      return if conversation.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != conversation.organization_id
    end

    # Anti-BOLA: l'account dev'essere membro dell'org della conversazione (specchio di
    # Ticketing::Subscription#account_belongs_to_organization).
    def account_belongs_to_organization
      org_id = conversation&.organization_id
      return if org_id.blank? || account.blank?
      return if Connections::Membership.exists?(account_id: account.id, organization_id: org_id)

      errors.add(:account, :not_member)
    end
  end
end
