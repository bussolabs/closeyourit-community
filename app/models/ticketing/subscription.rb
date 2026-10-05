# frozen_string_literal: true

module Ticketing
  # Sottoscrizione di un account a un ticket: il set di chi riceve le notifiche dei cambiamenti.
  # Auto-iscritti reporter/assignee/commentatore/menzionato; iscrizione manuale via "watch".
  # organization_id è denormalizzato (come Ticketing::Event) per blindare lo scoping tenant delle
  # notifiche; `source` registra COME ci si è iscritti (non viene declassato da ensure_for).
  class Subscription < ApplicationRecord
    belongs_to :ticket, class_name: "Ticketing::Ticket", inverse_of: :subscriptions
    belongs_to :account, class_name: "Accounts::Account", inverse_of: :ticket_subscriptions
    belongs_to :organization, class_name: "Organizations::Organization"

    enum :source, { manual: 0, reporter: 1, assignee: 2, commenter: 3, mentioned: 4 }, prefix: :source

    validates :account_id, uniqueness: { scope: :ticket_id }
    validate :organization_matches_ticket
    validate :account_belongs_to_organization

    scope :ordered, -> { order(:created_at) }

    # Iscrive l'account al ticket se non già iscritto (idempotente, race-safe). NON declassa la
    # source di una sottoscrizione esistente (un `manual` resta tale anche se poi commenta).
    # organization_id denormalizzato dal ticket. Usato sia dal controller "watch" sia dagli
    # auto-subscribe (reporter/assignee/commenter/mentioned). Ritorna la Subscription.
    def self.ensure_for(ticket:, account:, source: :manual)
      find_or_create_by(ticket: ticket, account: account) do |subscription|
        subscription.organization_id = ticket.project.organization_id
        subscription.source = source
      end
    rescue ActiveRecord::RecordNotUnique
      find_by(ticket: ticket, account: account)
    end

    private

    # Integrità tenant: l'org denormalizzata deve combaciare con quella reale del ticket (via
    # project). Specchio di Ticketing::Event#organization_matches_ticket.
    def organization_matches_ticket
      ticket_org_id = ticket&.project&.organization_id
      return if ticket_org_id.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != ticket_org_id
    end

    # Anti-BOLA: l'account dev'essere membro dell'org del ticket (specchio di
    # Comment#author_belongs_to_organization e TicketVote#account_belongs_to_ticket_organization).
    def account_belongs_to_organization
      org_id = ticket&.project&.organization_id
      return if org_id.blank? || account.blank?
      return if Connections::Membership.exists?(account_id: account.id, organization_id: org_id)

      errors.add(:account, :not_member)
    end
  end
end
