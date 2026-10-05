# frozen_string_literal: true

module Agents
  # Avvisa il CTO effettivo quando una nuova versione del piano è pronta. Il job rivalida destinatario
  # e visibilità al momento della consegna, quindi un override/revoca avvenuto dopo il planner non può
  # inviare dettagli del ticket al vecchio CTO. Le chiavi per-versione rendono i retry idempotenti.
  class PlanReadyNotificationJob < ApplicationJob
    def perform(plan_id)
      plan = Agents::Plan.includes(workflow: { ticket: { project: :organization } }).find_by(id: plan_id)
      return unless plan && plan == plan.workflow.plans.last

      workflow = plan.workflow
      ticket = workflow.ticket
      organization = workflow.organization
      cto = workflow.project.effective_cto
      return unless cto&.human? && cto.member_of_organization?(organization.id)
      return unless Authorization::VisibleScope.new(account: cto, organization:).projects.exists?(workflow.project.id)

      content = Ticketing::Notifications::Content.new(
        title: "#{ticket.code}: piano v#{plan.version} pronto per approvazione",
        body: plan.technical_analysis,
        url: Rails.application.routes.url_helpers.member_ticket_path(ticket)
      )
      event_type = :ticket_review_requested
      Ticketing::Notifications::Deliver.in_app(
        account: cto, ticket:, organization:, event_type:, content:,
        dedup_key: "agent-plan:#{plan.id}:#{cto.id}:in_app"
      )

      preference = Alerting::Preference.for(account: cto, organization:)
      decision = preference.channels_for(event_type, connected_telegram: false).fetch(:email)
      return unless decision[:deliver]

      Ticketing::Notifications::Deliver.email(
        account: cto, ticket:, organization:, event_type:, content:,
        dedup_key: "agent-plan:#{plan.id}:#{cto.id}:email",
        quiet: preference.quiet_now?, bucket: decision[:bucket]
      )
    end
  end
end
