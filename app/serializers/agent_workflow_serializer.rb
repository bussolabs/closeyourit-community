# frozen_string_literal: true

class AgentWorkflowSerializer < ApplicationSerializer
  # blocked_* accanto a cancelled_* (CYRA-218): senza, un client vede una lavorazione con tutti i
  # timestamp di una fase pronta e nessun motivo per cui non avanza — che è come appariva prima anche
  # a noi. Chi legge questo contratto deve poter distinguere "in corso" da "ferma, aspetta una persona".
  #
  # CYRA-598 — `blocked_kind` viaggia insieme agli altri: senza, il client resta cieco proprio sul
  # campo che distingue i due blocchi, e leggerebbe il motivo di un agente accanto a un blocco che
  # nessun agente ha scritto.
  attributes :id, :phase, :triage_requested_at, :triage_started_at, :triaged_at, :planned_at,
             :approved_at, :autopilot_started_at, :completed_at, :cancelled_at, :cancellation_reason,
             :blocked_at, :blocked_phase, :blocked_reason, :blocked_kind, :review_budget_from

  attribute(:current_plan) do |workflow|
    plan = workflow.plans.last
    next unless plan

    { version: plan.version, technical_analysis: plan.technical_analysis, scenarios: plan.scenarios,
      definition_of_done: plan.definition_of_done, mixed_parts: plan.mixed_parts, notes: plan.notes,
      approved_at: plan.approved_at, change_request: plan.change_request }
  end

  attribute(:clarifications) do |workflow|
    workflow.clarifications.order(:created_at).map do |item|
      { questions: item.questions.map(&:body), response: item.response_snapshot,
        answered_at: item.answered_at }
    end
  end

  attribute(:attempts) do |workflow|
    workflow.attempts.order(:created_at).map do |attempt|
      { id: attempt.id, phase: attempt.phase, runtime: attempt.runtime, status: attempt.status,
        reviewer_runtime: attempt.reviewer_runtime, review_status: attempt.review_status,
        started_at: attempt.started_at, finished_at: attempt.finished_at }
    end
  end
end
