# frozen_string_literal: true

module Connections
  # Invito a un'organizzazione (accept-flow). L'invio è in Fase C; qui il model + l'accettazione.
  class Invitation < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :invitations
    belongs_to :invited_by,
               class_name: "Accounts::Account",
               optional: true

    enum :role, { member: 0, admin: 1, owner: 2, customer: 3 }, default: :member

    generates_token_for :invitation, expires_in: Connections::Constants::TTL_INVITATION

    normalizes :email, with: ->(email) { email.strip.downcase }

    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    # Unica fra i soli inviti IN ATTESA, gemella dell'indice parziale a DB (indice pieno =
    # l'invito accettato, che nessuno cancella e la pagina Membri non mostra, teneva occupata
    # l'email per sempre e impediva di reinvitare chi era stato rimosso). Non si applica al record
    # che sta venendo accettato: AcceptInvitation fa `update!(accepted_at:)` sullo stesso record, e
    # un pendente omonimo comparso nel frattempo non deve impedirgli di chiudersi.
    validates :email, uniqueness: { scope: :organization_id, conditions: -> { where(accepted_at: nil) } },
              if: -> { accepted_at.nil? }
    validates :role, presence: true

    scope :pending, -> { where(accepted_at: nil) }

    def accepted?
      accepted_at.present?
    end
  end
end
