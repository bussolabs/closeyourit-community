# frozen_string_literal: true

module Agents
  # Annulla tutte le lavorazioni automatiche aperte di un'organizzazione (CYRA-867). Ognuna passa da
  # Agents::Workflows::Cancel, quindi valgono gli stessi controlli dell'annullamento singolo.
  # I ticket restano, senza automazione: una lavorazione nasce solo quando nasce il ticket.
  class CancelAllWorkflowsJob < ApplicationJob
    queue_as :batch

    def perform(organization_id, actor_id, reason)
      actor = Accounts::Account.find(actor_id)
      open_workflows(organization_id).find_each do |workflow|
        result = Agents::Workflows::Cancel.call(workflow: workflow, actor: actor, reason: reason)
        Rails.logger.info("[cancel_all] workflow #{workflow.id}: #{result.ok? ? "annullata" : result.error.message}")
      end
    end

    private

    def open_workflows(organization_id)
      Agents::Workflow.joins(ticket: :project)
                      .where(projects: { organization_id: organization_id }, cancelled_at: nil, completed_at: nil)
    end
  end
end
