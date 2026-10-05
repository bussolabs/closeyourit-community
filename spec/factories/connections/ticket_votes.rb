FactoryBot.define do
  factory :ticket_vote, class: "Connections::TicketVote" do
    association :ticket
    association :account

    # Integrità tenant: l'account dev'essere membro dell'org del ticket (validato sul model).
    after(:build) do |vote|
      next if vote.ticket.blank? || vote.account.blank?

      vote.account.save! if vote.account.new_record?
      org = vote.ticket.project&.organization
      next if org.blank?

      unless Connections::Membership.exists?(account_id: vote.account.id, organization_id: org.id)
        create(:membership, account: vote.account, organization: org)
      end
    end
  end
end
