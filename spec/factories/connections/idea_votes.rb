FactoryBot.define do
  factory :idea_vote, class: "Connections::IdeaVote" do
    association :idea
    association :account

    # Integrità tenant: l'account dev'essere membro dell'org dell'idea (validato sul model).
    after(:build) do |vote|
      next if vote.idea.blank? || vote.account.blank?

      vote.account.save! if vote.account.new_record?
      org = vote.idea.project&.organization
      next if org.blank?

      unless Connections::Membership.exists?(account_id: vote.account.id, organization_id: org.id)
        create(:membership, account: vote.account, organization: org)
      end
    end
  end
end
