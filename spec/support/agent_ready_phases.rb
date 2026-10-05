# frozen_string_literal: true

# CYRA-623 — mettere una lavorazione nella fase PRONTA che si vuole provare. La prontezza non è un
# campo: è la combinazione di date che `Agents::Workflow::READY_EXECUTION_PHASE_SQL` legge, e
# ricomporla a mano in ogni file significherebbe che una prova passa perché il montaggio è sbagliato —
# il ticket non sarebbe stato servito comunque.
#
# Ogni ramo scrive anche le date dei passi PRECEDENTI: senza, vincerebbe una fase più in su e la prova
# girerebbe su una fase diversa da quella che dichiara.
module AgentReadyPhases
  def pronta_per!(workflow, fase, now: 1.minute.ago)
    attributi = case fase.to_s
    when "triage" then { triage_requested_at: now }
    when "planner" then { triage_requested_at: now, triage_started_at: now, triaged_at: now }
    when "autopilot"
      { triage_requested_at: now, triage_started_at: now, triaged_at: now, planned_at: now, approved_at: now }
    when "closer_staging"
      { triage_requested_at: now, triage_started_at: now, triaged_at: now, planned_at: now, approved_at: now,
        autopilot_started_at: now, autopilot_completed_at: now, candidate_verified_at: now,
        autopilot_approved_at: now }
    when "closer_production"
      { triage_requested_at: now, triage_started_at: now, triaged_at: now, planned_at: now, approved_at: now,
        autopilot_started_at: now, autopilot_completed_at: now, candidate_verified_at: now,
        autopilot_approved_at: now, closer_staging_started_at: now, closer_staging_completed_at: now,
        # CYRA-871 — pronta vuol dire anche freno libero: la prova dello staging ha più di 2 ore.
        closer_staging_verified_at: now - ::Agents::Workflows::ProductionHold::WINDOW,
        closer_production_approved_at: now }
    else raise ArgumentError, "fase non prevista: #{fase}"
    end
    workflow.update!(**attributi)
    # CYRA-682 — le fasi che TOCCANO il repository non arrivano in coda senza il vincolo congelato
    # all'approvazione: su quale archivio può nascere il lavoro e qual è la prova che dirà «fatto».
    # Montarle senza sarebbe uno stato che in produzione non esiste — un piano si approva, e
    # approvandolo il vincolo si congela — e il test parlerebbe di un caso impossibile.
    congela_vincolo!(workflow) if ::Agents::PhaseProfile.fetch(fase.to_s).write_access?
    # La prova di montaggio: se la fase pronta non è quella che si è chiesta, tutto il resto del test
    # parlerebbe di un'altra cosa.
    raise "montaggio sbagliato: #{workflow.reload.ready_execution_phase.inspect}" unless
      workflow.ready_execution_phase == fase.to_s

    workflow
  end

  # Il piano approvato col suo vincolo, come lo scrive Workflows::ApprovePlan. Il repository del
  # progetto quando c'è: il vincolo nomina l'archivio su cui il lavoro può nascere, e inventarne uno
  # farebbe passare una prova che in produzione si fermerebbe.
  def congela_vincolo!(workflow)
    return if workflow.frozen_plan&.candidate_items.present?

    repo = workflow.ticket.project.github_repository
    piano = workflow.plans.order(:version).last || ::Agents::Plan.create!(
      workflow:, attempt: create(:agent_attempt, workflow:, organization: workflow.organization, phase: "planner"),
      technical_analysis: "Piano", scenarios: [], definition_of_done: [ "RSpec" ], notes: [],
      ticket_snapshot_digest: workflow.ticket_snapshot_digest.presence || "snapshot"
    )
    nome = repo&.full_name || "bussolabs/montaggio"
    piano.update!(candidate_items: [ { "repo" => nome, "base" => repo&.default_branch || "main" } ],
                  completion_probe: { "kind" => "merge", "repo" => nome })
    workflow.update!(frozen_plan: piano, plan_frozen_at: workflow.approved_at || Time.current)
  end

  # Il prerequisito col codice UNITO e visto dal server (CYRA-620): la fase di staging chiusa dal
  # verificatore, non dalla dichiarazione della macchina.
  def prerequisito_unito!(blocker, now: 5.minutes.ago)
    blocker.agent_workflow.update!(closer_staging_completed_at: now, closer_staging_verified_at: now)
  end

  # Lo stesso stato, ma chiuso dalla SOLA parola dell'agente: è la differenza che tiene in piedi tutto.
  def prerequisito_dichiarato!(blocker, now: 5.minutes.ago)
    blocker.agent_workflow.update!(closer_staging_completed_at: now, closer_staging_verified_at: nil)
  end
end

RSpec.configure { |config| config.include AgentReadyPhases }
