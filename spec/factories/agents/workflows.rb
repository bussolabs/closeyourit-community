# frozen_string_literal: true

# Workflow e tentativi vivono nel modello host-first e sopravvivono alla rimozione dei typed agent (MT-9):
# stavano nello stesso file delle factory del catalogo solo per accidente storico. Un attempt nasce dalla
# FASE e dall'host che la esegue — niente agente, comando o istruzione.
FactoryBot.define do
  factory :agent_workflow, class: "Agents::Workflow" do
    transient { organization { FactoryReuse.organization } }
    ticket { create(:ticket, organization:) }
    triage_requested_at { Time.current }

    # Lo staging è concluso e la produzione aspetta il via libera umano (CYRA-504): è il punto in cui
    # la lavorazione si ferma da sola, e il fixture di ogni prova sul gate nuovo. La catena è COMPLETA
    # e monotòna come in produzione — un workflow reale non salta i timestamp intermedi, e saltarli
    # qui farebbe rispondere `triage` alla prontezza della fase.
    trait :closer_staging_completed do
      triage_started_at { 5.hours.ago }
      triaged_at { 4.hours.ago }
      planned_at { 3.5.hours.ago }
      approved_at { 3.hours.ago }
      autopilot_started_at { 2.5.hours.ago }
      autopilot_completed_at { 2.2.hours.ago }
      autopilot_approved_at { 2.hours.ago }
      closer_staging_started_at { 90.minutes.ago }
      closer_staging_completed_at { 1.hour.ago }
      # CYRA-620 — «consegnato» e «visto» sono due cose diverse, e questo tratto è il punto in cui la
      # lavorazione aspetta il via libera umano: ci arriva solo dopo che il sistema ha visto atterrare
      # il codice approvato. Chi vuole provare il momento del controllo azzera questo campo.
      closer_staging_verified_at { 1.hour.ago }
      candidate_verified_at { 2.2.hours.ago }
    end
  end

  factory :agent_attempt, class: "Agents::Attempt" do
    workflow factory: :agent_workflow
    organization { workflow.ticket.project.organization }
    host { create(:agent_host, organization:) }
    # Identità di esecuzione host-first: service account dell'host + skill della fase. È l'unica ammessa.
    service_account do
      create(:account, :service).tap { |account| create(:membership, account:, organization:) }
    end
    skill_key { "/closeyourit-triage" }
    runtime { "claude" }
    phase { "triage" }
    status { :running }
    sequence(:idempotency_key) { |n| "attempt-#{n}" }
    sequence(:external_run_id) { |n| "run-#{n}" }
    started_at { Time.current }
    result { {} }
    review { {} }
  end
end
