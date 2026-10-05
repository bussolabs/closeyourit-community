FactoryBot.define do
  factory :ticket_question, class: "Ticketing::Question" do
    transient { organization { FactoryReuse.organization } }

    ticket { create(:ticket, organization: organization) }
    author do
      create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
    end
    # Deterministico e non Faker: col tetto attivo un testo di lunghezza casuale renderebbe
    # randomicamente invalido ogni create(:ticket_question). Stessa scelta di
    # spec/factories/ticketing/comments.rb, e per la stessa ragione.
    sequence(:body) { |n| "Domanda #{n}?" }

    trait :blocking do
      blocking { true }
    end

    trait :shared do
      audience { :shared }
    end

    trait :from_agent do
      origin { :agent }
    end

    trait :answered do
      answered_at { Time.current }
    end
  end
end
