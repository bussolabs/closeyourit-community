# frozen_string_literal: true

# Snapshot completo del ticket candidato per il preflight Automator. I riferimenti di workflow usano
# id/code/category stabili oltre alle label umane; repository e branch derivano dal progetto server-side.
class AgentTicketCandidateSerializer < ApplicationSerializer
  attributes :id, :title, :description, :technical_analysis, :weight, :due_at,
             :created_at, :updated_at, :closed_at

  attribute(:code) { |ticket| ticket.code }
  attribute(:kind) { |ticket| ticket.kind }
  # Gate di eleggibilità agenti (CYRA-184). Additivo: `candidate` dichiara additionalProperties: true
  # nel contratto agent-queue/v1, quindi non tocca schema/SHA256SUMS. Oltre a rendere leggibile
  # all'automator PERCHÉ un ticket è in coda, entra in Selection.candidate_version: cambiare
  # l'eleggibilità invalida da sé le selezioni già firmate, in aggiunta al re-check sotto lock.
  attribute(:agent_eligibility) { |ticket| ticket.agent_eligibility }

  attribute :workflow do |ticket|
    workflow = ticket.agent_workflow
    current_plan = workflow.plans.last
    payload = {
      id: workflow.id,
      phase: workflow.phase,
      # Host-first (CYAU-87): la execution_phase AUTORITATIVA pre-claim (uno dei 5 PhaseProfile::PHASES),
      # allineata al vocabolario del lease post-claim. `#phase` (FSM) non è mappabile per il planner
      # (planning/review_blocked) → l'automator deriva runtime/skill/sandbox da questa, non dallo stato FSM.
      execution_phase: workflow.ready_execution_phase,
      snapshot_version: workflow.ticket_snapshot_version,
      snapshot_digest: workflow.ticket_snapshot_digest,
      # CYAU-177 — QUALE versione del piano è quella congelata all'approvazione. Serve perché il campo
      # qui sotto è `plans.last`, che non è per forza la congelata: senza un modo di verificarlo,
      # l'host comporrebbe il vincolo di scope da un piano che nessuno ha approvato. L'host confronta
      # le due e, se non coincidono, non compone niente e si ferma — meglio un ticket fermo col motivo
      # scritto che una macchina che lavora su una spec sbagliata. Nil finché non è stato congelato.
      frozen_plan_version: workflow.frozen_plan&.version,
      # CYAU-249 — when a person last said "redo" (retry, reject, plan changes): the machine restarts its own
      # attempt series from here, or the next round would block the ticket again on the old count.
      budget_from: workflow.review_budget_from&.iso8601(3)
    }
    # Il commit che una persona ha approvato (CYRA-612: `review_candidate`, scritto una volta sola).
    # La fase di rilascio lo esige «dal server» e non dal ramo, che nel frattempo può essersi mosso;
    # senza questo campo la skill non aveva da dove prenderlo. Forma attesa dall'host
    # (`frozenHead` in ticket-preflight.ts): repo, number, head_sha, base_ref.
    candidate = workflow.review_candidate
    if candidate&.head_sha.present?
      payload[:frozen_candidate] = {
        repo: candidate.repository_full_name, number: candidate.number,
        head_sha: candidate.head_sha, base_ref: candidate.base_ref
      }
    end
    # `approved_at`/`approved_by` distinguono il PIANO APPROVATO dal piano precedente ancora in
    # discussione: senza, l'automator riceve gli stessi campi nei due casi e non può che presentarli
    # entrambi come materiale non fidato («Piano precedente vN»). L'agente autopilot, a cui la skill
    # chiede una spec approvata, non ne trovava allora nessuna e si fermava — pur essendo in una fase
    # che il server assegna solo dopo l'approvazione. Additivo: il contratto agent-queue/v1 dichiara
    # `additionalProperties: true`, quindi non tocca schema né SHA256SUMS.
    if current_plan
      payload[:current_plan] = {
        version: current_plan.version, contract_version: current_plan.contract_version,
        content: current_plan.content, technical_analysis: current_plan.technical_analysis,
        scenarios: current_plan.scenarios, definition_of_done: current_plan.definition_of_done,
        mixed_parts: current_plan.mixed_parts, notes: current_plan.notes,
        change_request: current_plan.change_request,
        approved_at: current_plan.approved_at,
        approved_by: current_plan.approved_by&.name,
        # CYAU-177 — le due decisioni che l'approvazione ha congelato (CYRA-610): su quale archivio il
        # lavoro può nascere e da quale punto, e qual è la prova che dirà «fatto». Viaggiano fin qui
        # perché è la sessione dell'agente a doverle rispettare, e finora non le riceveva: deduceva da
        # sé dove aprire la proposta e quando dirsi finita. Nulle sui piani approvati prima di CYRA-610
        # o su un progetto non configurato: l'host lo legge come vincolo assente, che è la verità.
        candidate_items: current_plan.candidate_items,
        completion_probe: current_plan.completion_probe
      }
    end
    rework = AgentTicketCandidateSerializer.rework_for(workflow)
    payload[:rework] = rework if rework
    payload
  end

  # CYAU-236 — what the review of the previous attempt asked to fix. Without it a retry after
  # changes_requested only had the plan, found its own open PR and declared the work already delivered.
  # Only blocking findings (not "info"), capped: a review is model output, so it travels as untrusted
  # material for the session to read, never as an order.
  REWORK_FINDINGS_LIMIT = 10
  REWORK_TEXT_LIMIT = 600

  def self.rework_for(workflow)
    phase = workflow.ready_execution_phase
    return unless phase

    # The claim creates the new attempt BEFORE this payload is built, so "the last attempt" is the one
    # just started: skip attempts still open and those that ended without a verdict (stale, cancelled).
    last = workflow.attempts.where(phase:).where.not(status: %w[running awaiting_review stale cancelled])
                   .order(:created_at).last
    # The server keeps a rejected delivery as `review_failed`, and its review_status is not always
    # `changes_requested` (LAB-70 had `unavailable` next to two major findings): what matters is that the
    # attempt was rejected and its review left blocking findings.
    return unless last && (last.status == "review_failed" || last.review_status == "changes_requested")

    findings = Array(last.review&.dig("findings")).filter_map do |finding|
      next unless finding.is_a?(Hash) && finding["severity"].present? && finding["severity"] != "info"

      { severity: finding["severity"].to_s, title: finding["title"].to_s.truncate(REWORK_TEXT_LIMIT),
        detail: finding["detail"].to_s.truncate(REWORK_TEXT_LIMIT) }
    end.first(REWORK_FINDINGS_LIMIT)
    return if findings.empty?

    { phase:, attempt_id: last.id, findings: }
  end

  attribute :project do |ticket|
    repository = ticket.project.github_repository
    {
      id: ticket.project_id,
      key: ticket.project.key,
      repo: repository&.full_name,
      default_branch: repository&.default_branch
    }
  end

  attribute :status do |ticket|
    {
      id: ticket.status_id,
      code: ticket.status.code,
      label: ticket.status.label,
      category: ticket.status.category
    }
  end

  attribute :priority do |ticket|
    { id: ticket.priority_id, code: ticket.priority.code, label: ticket.priority.label }
  end

  attribute :assignee do |ticket|
    { id: ticket.assignee_id, name: ticket.assignee.name } if ticket.assignee
  end

  attribute :reporter do |ticket|
    { id: ticket.reporter_id, name: ticket.reporter.name }
  end

  attribute :reviewer do |ticket|
    { id: ticket.reviewer_id, name: ticket.reviewer.name } if ticket.reviewer
  end

  attribute :milestone do |ticket|
    next unless ticket.milestone

    {
      id: ticket.milestone_id,
      code: ticket.milestone.code,
      label: ticket.milestone.label,
      due_on: ticket.milestone.due_on
    }
  end

  attribute :platforms do |ticket|
    ticket.platforms.sort_by { |platform| [ platform.position, platform.label ] }.map do |platform|
      { id: platform.id, code: platform.code, label: platform.label }
    end
  end

  attribute :scenarios do |ticket|
    ticket.scenarios.map do |scenario|
      {
        title: scenario.title,
        step_given: scenario.step_given,
        step_when: scenario.step_when,
        step_then: scenario.step_then,
        step_expected: scenario.step_expected
      }
    end
  end

  attribute(:conditions) do |ticket|
    ticket.conditions.map { |condition| { text: condition.text } }
  end

  attribute :comments do |ticket|
    ticket.comments.map do |comment|
      {
        id: comment.id,
        body: comment.body,
        author: { id: comment.author_id, name: comment.author.name },
        created_at: comment.created_at,
        updated_at: comment.updated_at
      }
    end
  end

  # CYAU-240 — the decisions taken through clarification answers travel with the work, so the diff
  # review does not reject a choice an answer already settled.
  attribute :answered_questions, &:answered_question_decisions
end
