FactoryBot.define do
  factory :idea, class: "Ideas::Idea" do
    transient do
      organization { create(:organization) }
    end

    project { create(:project, organization: organization) }
    # Autore membro dell'org del progetto (richiesto dall'isolamento tenant).
    author do
      create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
    end
    # Valori univoci espliciti (non Faker): le asserzioni anti-leak (`not_to include`)
    # devono poter contare su titoli mai collidenti tra org diverse.
    sequence(:title) { |n| "Idea #{n}" }
    sequence(:problem) { |n| "Problema #{n}: cosa non funziona oggi per il team." }
    sequence(:solution) { |n| "Soluzione #{n}: come lo risolviamo." }
    stakeholders { [] }
    status { :open }

    trait :archived do
      status { :archived }
    end

    # Idea già promossa a ticket (congelata, backlink valorizzato).
    trait :converted do
      status { :converted }
      converted_at { Time.current }
      ticket { create(:ticket, organization: organization, project: project) }
    end
  end
end
