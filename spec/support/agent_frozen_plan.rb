# frozen_string_literal: true

# CYRA-612 — approvando il piano vengono FISSATI i progetti su cui quel lavoro può uscire (CYRA-610),
# e la consegna viene respinta se la proposta sta altrove. Quasi ogni spec che consegna un autopilot ha
# quindi bisogno di un piano congelato: sta qui e non copiato in ogni file, perché la forma delle due
# colonne è un contratto e sbagliarla in un file solo darebbe un rosso che sembra del codice.
module AgentFrozenPlan
  DEFAULT_REPO = "bussolabs/closeyourit-rails"

  # Congela sul piano corrente della lavorazione l'elenco dei progetti ammessi e la prova di
  # completamento, e lo dichiara come il piano approvato. Scrive direttamente, senza passare da
  # ApprovePlan: qui serve lo STATO, non il gesto — e il gesto ha già i suoi spec.
  # CYRA-624 — `kind:` è il tipo di prova che il progetto dichiara: `merge` (il codice unito) o
  # `deploy_smoke` (il rilascio in piedi in produzione). Il default resta quello di ieri, così le
  # prove già scritte non cambiano significato.
  # CYRA-625 — `registry:` e `package:` sono le coordinate dello scaffale, per la prova del pacchetto.
  def congela_piano!(workflow, repo: DEFAULT_REPO, base: "main", kind: "merge", environment_id: nil,
                     registry: nil, package: nil)
    plan = workflow.plans.order(:version).last || Agents::Plan.create!(
      workflow:, attempt: create(:agent_attempt, organization: workflow.organization, workflow:),
      technical_analysis: "Piano", scenarios: [], definition_of_done: [ "RSpec" ], notes: [],
      ticket_snapshot_digest: "snapshot"
    )
    plan.update!(candidate_items: [ { "repo" => repo, "base" => base } ],
                 completion_probe: { "kind" => kind, "repo" => repo,
                                     "environment_id" => environment_id,
                                     "registry" => registry, "package" => package }.compact)
    workflow.update!(frozen_plan: plan, plan_frozen_at: Time.current)
    plan
  end
end

RSpec.configure do |config|
  config.include AgentFrozenPlan
end
