FactoryBot.define do
  factory :ticket, class: "Ticketing::Ticket" do
    transient do
      # L'organizzazione già in scena, se c'è: un ticket in più non deve coniare un tenant in più
      # (CYRA-855). La prova che ne vuole una seconda la passa. Non serve quando arriva `project`.
      organization { FactoryReuse.organization }
      # Il factory aggiunge uno scenario di default (corpo minimo) se non c'è description né scenari.
      # Metti a false per costruire un ticket a corpo vuoto (test della validazione requires_some_body).
      with_default_body { true }
      # Il flusso agenti è un dominio a parte: lo chiede la prova che lo verifica (CYRA-855).
      with_agent_workflow { false }
    end

    project { organization.projects.order(:created_at, :id).first || create(:project, organization: organization) }
    # Contorno riusato da chi possiede il PROGETTO, non dalla transient: con `project` esplicito le
    # due possono divergere e le validazioni tenant legano status, priorità e autore alla prima.
    # Con `project: nil` (prove sulla validazione) si ricade sulla transient.
    status do
      owner = project&.organization || organization
      # Mai uno stato di chiusura: un ticket di serie che nasce risolto cambia in silenzio il senso
      # della prova che lo crea.
      owner.ticket_statuses.category_open.order(:created_at, :id).first ||
        create(:ticket_status, organization: owner)
    end
    priority do
      owner = project&.organization || organization
      owner.ticket_priorities.order(:created_at, :id).first || create(:ticket_priority, organization: owner)
    end
    # reporter membro dell'org del progetto (richiesto dall'isolamento tenant)
    reporter do
      owner = project&.organization || organization
      owner.accounts.order("accounts.created_at", "accounts.id").first ||
        create(:account).tap do |account|
          create(:membership, account: account, organization: owner, role: :member)
        end
    end
    # Il revisore nasce = reporter (come CreateTicket). I test che verificano l'assenza lo azzerano.
    reviewer { reporter }
    title { Faker::Lorem.sentence }

    # kind default = bug. Il corpo (description/scenari/DoD/technical_analysis) è uguale per tutti i kind.
    kind { :bug }

    # Corpo minimo di default: uno scenario BDD (soddisfa requires_some_body). I trait che valorizzano
    # description restano "description-only" senza scenario aggiunto.
    after(:build) do |ticket, evaluator|
      next unless evaluator.with_default_body
      next if ticket.description.present?
      next if ticket.scenarios.reject(&:marked_for_destruction?).any?(&:steps?)

      ticket.scenarios << build(:ticketing_scenario, ticket: ticket)
    end

    after(:create) do |ticket, evaluator|
      ticket.create_agent_workflow!(triage_requested_at: Time.current) if evaluator.with_agent_workflow && !ticket.agent_workflow
    end

    # Ticket "da testo semplice": solo la description libera, nessuno scenario.
    trait :plain_bug do
      kind { :bug }
      description { Faker::Lorem.paragraph }
    end

    trait :story do
      kind { :story }
      description { Faker::Lorem.paragraph }
    end

    trait :task do
      kind { :task }
      description { Faker::Lorem.paragraph }
    end

    # Epic: il contenitore. I figli si agganciano con `parent:` (stesso progetto).
    trait :epic do
      kind { :epic }
      description { Faker::Lorem.paragraph }
    end

    # Corpo strutturato: N scenari BDD.
    trait :with_scenarios do
      transient { scenarios_count { 2 } }
      after(:build) do |ticket, evaluator|
        ticket.scenarios = build_list(:ticketing_scenario, evaluator.scenarios_count, ticket: ticket)
      end
    end

    # N condizioni DoD.
    trait :with_conditions do
      transient { conditions_count { 2 } }
      after(:build) do |ticket, evaluator|
        ticket.conditions = build_list(:ticketing_condition, evaluator.conditions_count, ticket: ticket)
      end
    end

    # Ticket che una persona ha consentito agli agenti (CYRA-184, CYRA-770). La sorgente è `human`
    # perché dal CYRA-770 è l'UNICA che possa muovere la decisione: un parere dell'AI non mette
    # niente in coda. Il default della factory resta `pending` come quello della colonna — un ticket
    # non è lavorabile finché qualcuno non lo consente, e gli spec del dominio agenti devono
    # dichiarare questa precondizione invece di ereditarla di nascosto.
    trait :agent_workable do
      agent_eligibility { :allowed }
      agent_eligibility_source { :human }
      agent_eligibility_reason { "Lavoro di sviluppo ordinario e reversibile." }
      agent_eligibility_decided_at { Time.current }
    end

    # Ticket fermato da una persona: nessun agente può reclamarlo.
    trait :agent_blocked do
      agent_eligibility { :blocked }
      agent_eligibility_source { :human }
      agent_eligibility_reason { "Il ticket chiede un'operazione distruttiva sul database di produzione." }
      agent_eligibility_decided_at { Time.current }
    end

    # Solo il PARERE dell'AI, senza nessuna decisione: è lo stato in cui il percorso automatico
    # lascia un ticket, e quello in cui il ticket NON deve raggiungere la coda degli agenti.
    trait :agent_advice_allowed do
      agent_eligibility_advice { :allowed }
      agent_eligibility_advice_reason { "Lavoro di sviluppo ordinario e reversibile." }
      agent_eligibility_checksum { "checksum-del-parere" }
      agent_eligibility_evaluated_at { Time.current }
    end
  end
end
