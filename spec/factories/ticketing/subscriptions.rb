FactoryBot.define do
  factory :ticket_subscription, class: "Ticketing::Subscription" do
    association :ticket
    association :account
    source { :manual }

    # Integrità tenant: org denormalizzata dal ticket + account reso membro dell'org (come :ticket_vote).
    after(:build) do |subscription|
      next if subscription.ticket.blank? || subscription.account.blank?

      subscription.account.save! if subscription.account.new_record?
      org = subscription.ticket.project&.organization
      next if org.blank?

      subscription.organization ||= org
      unless Connections::Membership.exists?(account_id: subscription.account.id, organization_id: org.id)
        create(:membership, account: subscription.account, organization: org)
      end
    end
  end
end
