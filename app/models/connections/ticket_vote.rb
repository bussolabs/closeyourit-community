module Connections
  # Voto (upvote) di un account su un ticket. Un account vota un ticket una volta sola
  # (unicità [account_id, ticket_id]). Vota chiunque vede il ticket; l'integrità tenant
  # garantisce che l'account sia membro dell'org del ticket. counter_cache → ticket.votes_count.
  class TicketVote < ApplicationRecord
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :ticket_votes
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :votes,
               counter_cache: :votes_count

    validates :account_id, uniqueness: { scope: :ticket_id }
    validate :account_belongs_to_ticket_organization

    private

    # Integrità tenant: l'account deve avere una membership nell'org del ticket (via il progetto).
    # Stesso spirito di ProjectMembership, ma l'org si raggiunge attraverso ticket → project.
    def account_belongs_to_ticket_organization
      return if account.blank? || ticket.blank?

      org_id = ticket.project&.organization_id
      return if org_id.blank?

      member = Connections::Membership.exists?(account_id: account_id, organization_id: org_id)
      errors.add(:account, :invalid) unless member
    end
  end
end
