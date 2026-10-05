module Connections
  # Voto (upvote) di un account su un'idea. Un account vota un'idea una volta sola
  # (unicità [account_id, idea_id]). Vota chiunque vede l'idea; l'integrità tenant
  # garantisce che l'account sia membro dell'org dell'idea. counter_cache → idea.votes_count.
  class IdeaVote < ApplicationRecord
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :idea_votes
    belongs_to :idea,
               class_name: "Ideas::Idea",
               inverse_of: :votes,
               counter_cache: :votes_count

    validates :account_id, uniqueness: { scope: :idea_id }
    validate :account_belongs_to_idea_organization

    private

    # Integrità tenant: l'account deve avere una membership nell'org dell'idea (via il
    # progetto). Clone di Connections::TicketVote#account_belongs_to_ticket_organization.
    def account_belongs_to_idea_organization
      return if account.blank? || idea.blank?

      org_id = idea.project&.organization_id
      return if org_id.blank?

      member = Connections::Membership.exists?(account_id: account_id, organization_id: org_id)
      errors.add(:account, :invalid) unless member
    end
  end
end
