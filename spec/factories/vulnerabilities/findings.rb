# frozen_string_literal: true

FactoryBot.define do
  factory :vulnerability_finding, class: "Vulnerabilities::Finding" do
    package { create(:vulnerability_package) }
    advisory { create(:vulnerability_advisory) }
    # Il progetto è quello del manifest che contiene il pacchetto: è denormalizzato, non arbitrario.
    project { package.manifest.project }
    fixed_version { "1.2.3" }
    status { :open }
    first_seen_at { 2.days.ago }
    last_seen_at { Time.current }

    trait :resolved do
      status { :resolved }
      resolved_at { Time.current }
    end

    trait :ignored do
      status { :ignored }
      triage_note { "Non raggiungibile dal nostro codice." }
    end

    trait :critical do
      advisory { create(:vulnerability_advisory, :critical) }
    end

    trait :high do
      advisory { create(:vulnerability_advisory, :high) }
    end

    # OSV non dichiara una versione che risolve: non c'è aggiornamento da suggerire.
    trait :unfixable do
      fixed_version { nil }
    end

    # `organization` è transient sulla factory dei ticket e da lì nascono stato, priorità e reporter:
    # passare solo `project` lascerebbe quei tre in un'altra organizzazione e il ticket non valida.
    trait :promoted do
      ticket do
        project = package.manifest.project
        create(:ticket, organization: project.organization, project: project)
      end
    end
  end
end
