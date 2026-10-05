FactoryBot.define do
  factory :idea_comment, class: "Ideas::Comment" do
    transient { organization { create(:organization) } }

    idea { create(:idea, organization: organization) }
    author do
      create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
    end
    sequence(:body) { |n| "Commento #{n} sull'idea." }

    # Commento lungo ma legittimo (CYRA-371: il tetto delle idee è di qualche migliaio di caratteri,
    # quindi non serve più aggirare le validazioni). Sopra il clamp del prompt AI: serve a chi testa
    # che un intervento davvero lungo non passi intero nel contesto.
    trait :long do
      body { "x" * 2_000 }
    end
  end
end
