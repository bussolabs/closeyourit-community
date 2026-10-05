FactoryBot.define do
  factory :ticket_answer, class: "Ticketing::Answer" do
    transient { organization { FactoryReuse.organization } }

    question { create(:ticket_question, organization: organization) }
    author do
      create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
    end
    sequence(:body) { |n| "Risposta #{n}." }

    trait :covers_round do
      covers_round { true }
    end
  end
end
