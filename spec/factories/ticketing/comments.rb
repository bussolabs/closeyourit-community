FactoryBot.define do
  factory :ticket_comment, class: "Ticketing::Comment" do
    transient { organization { FactoryReuse.organization } }

    ticket { create(:ticket, organization: organization) }
    author do
      create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
    end
    # Deterministico, NON Faker::Lorem.paragraph: quello genera 3-6 frasi e supera i 240 caratteri in
    # modo casuale, quindi col tetto ogni create(:ticket_comment) sarebbe randomicamente invalido —
    # verde in locale e rosso in CI a giorni alterni. Gemello di spec/factories/ideas/comments.rb.
    sequence(:body) { |n| "Commento #{n}." }

    # Commento storico già oltre il tetto: salvato aggirando le validazioni, come le righe scritte
    # prima che il tetto esistesse. Serve ai test della salvaguardia legacy e della compattazione.
    trait :long do
      body { "Resoconto storico. #{"x" * 400}" }
      to_create { |instance| instance.save!(validate: false) }
    end
  end
end
