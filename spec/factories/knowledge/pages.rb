# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_page, class: "Knowledge::Page" do
    transient do
      # Progetto opzionale: se passato, l'org deriva da lui (niente mismatch tenant nel join).
      project { nil }
      organization { project&.organization || create(:organization) }
      # false → pagina "generale" org-wide (nessun progetto/gruppo): usa il trait :org_wide.
      scoped { true }
    end

    created_by do
      create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :member)
      end
    end
    title { Faker::Lorem.sentence }
    body { Faker::Lorem.paragraph }
    kind { :note }

    # Di default la pagina è collegata a UN progetto (come prima del multi-scope) e ne eredita l'org,
    # così le spec che passano `project:` restano invariate. Per N progetti/gruppi assegnarli dopo.
    after(:build) do |page, evaluator|
      page.organization ||= evaluator.organization
      if evaluator.project
        page.projects << evaluator.project unless page.projects.include?(evaluator.project)
      elsif evaluator.scoped
        page.projects << create(:project, organization: page.organization)
      end
    end

    trait :decision do
      kind { :decision }
    end

    # Sezione tecnica opzionale (default: assente). La usa chi testa embedding/tab/versioning del tecnico.
    trait :with_tech_spec do
      tech_spec { "Indice HNSW su embedding vector(1024), opclass vector_cosine_ops." }
    end

    # Pagina generale org-wide: nessun progetto/gruppo, valida per tutta l'organizzazione.
    trait :org_wide do
      scoped { false }
    end

    # Proposta in attesa di revisione (CYRA-298): fuori da ricerca, RAG, correlate e liste.
    trait :in_review do
      status { :in_review }
      review_note { "Errore di deploy risolto: la variabile mancava solo in staging." }
    end

    # Proposta già scartata: resta fuori da tutto, serve solo a non farla riproporre.
    trait :rejected do
      status { :rejected }
      reviewed_at { Time.current }
    end

    trait :with_tags do
      tags { %w[flutter flutter-flavor] }
    end

    # CYRA-419: pagina scritta da un assistente con l'accesso di created_by. L'origine è l'etichetta
    # dichiarata da chi ha scritto (assistente, skill o canale usato).
    trait :written_by_agent do
      author_kind { :agent }
      author_origin { "kb-inbox" }
    end

    # Scritta da una persona dentro l'app.
    trait :written_by_human do
      author_kind { :human }
    end
  end
end
