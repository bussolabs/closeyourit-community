# frozen_string_literal: true

module Chat
  # Messaggio di una conversazione. author opzionale (nullify): il thread sopravvive alla cancellazione
  # dell'autore. Soft delete via deleted_at (render "messaggio eliminato" senza spezzare la timeline).
  # Le risorse taggate vivono in Chat::MessageReference; gli allegati via Attachable (has_many_attached
  # :files). Contenuto minimo richiesto: testo o allegato (il token di una risorsa taggata sta nel body).
  class Message < ApplicationRecord
    include Attachable

    belongs_to :conversation, class_name: "Chat::Conversation", inverse_of: :messages
    belongs_to :author, class_name: "Accounts::Account", optional: true
    belongs_to :organization, class_name: "Organizations::Organization"

    has_many :references, class_name: "Chat::MessageReference", inverse_of: :message, dependent: :destroy

    normalizes :body, with: ->(value) { value.to_s.strip.presence }

    validate :organization_matches_conversation
    validate :author_belongs_to_organization
    validate :content_present

    scope :chronological, -> { order(:created_at, :id) }
    scope :kept, -> { where(deleted_at: nil) }

    def deleted? = deleted_at.present?

    def soft_delete!
      update!(deleted_at: Time.current)
    end

    private

    # Un messaggio deve portare almeno testo o un allegato (una risorsa taggata lascia il suo token nel
    # body → body presente). Un messaggio soft-deleted è esente (il body viene svuotato).
    def content_present
      return if deleted?
      return if body.present? || files.attached?

      errors.add(:base, :empty)
    end

    def organization_matches_conversation
      return if conversation.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != conversation.organization_id
    end

    # Anti-BOLA: se presente, l'autore dev'essere membro dell'org della conversazione.
    def author_belongs_to_organization
      org_id = conversation&.organization_id
      return if org_id.blank? || author.blank?
      return if Connections::Membership.exists?(account_id: author.id, organization_id: org_id)

      errors.add(:author, :not_member)
    end
  end
end
