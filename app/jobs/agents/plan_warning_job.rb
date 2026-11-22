# frozen_string_literal: true

module Agents
  # CYRA-1345 — tells the effective CTO that a plan went ahead with reasons a person used to decide on:
  # the risk and each reason in plain words. In-app always, then Telegram or email as their preferences
  # say. The recipient and their sight of the project are checked again at delivery, and the keys per
  # decision make a retry send nothing twice.
  class PlanWarningJob < ApplicationJob
    EVENT_TYPE = :ticket_review_requested

    def perform(decision_id)
      decision = Agents::SupporterDecision.includes(workflow: { ticket: { project: :organization } }).find_by(id: decision_id)
      return unless decision&.outcome == "approved" && Array(decision.evidence["reasons"]).any?

      workflow = decision.workflow
      organization = workflow.organization
      cto = workflow.project.effective_cto
      return unless cto&.human? && cto.member_of_organization?(organization.id)
      return unless Authorization::VisibleScope.new(account: cto, organization:).projects.exists?(workflow.project.id)

      args = { account: cto, ticket: workflow.ticket, organization:, event_type: EVENT_TYPE,
               content: I18n.with_locale(cto.effective_locale) { content(decision) } }
      key = ->(via) { "agent-plan-warning:#{decision.id}:#{cto.id}:#{via}" }
      Ticketing::Notifications::Deliver.in_app(**args, dedup_key: key.call("in_app"))

      preference = Alerting::Preference.for(account: cto, organization:)
      channels = preference.channels_for(EVENT_TYPE, connected_telegram: cto.connected_telegram?)
      telegram = channels[:telegram]
      sent = (Ticketing::Notifications::Deliver.telegram(**args, dedup_key: key.call("telegram"), bucket: telegram[:bucket]) if telegram[:deliver])
      return if ::Notifications::Deliver.reached_by_telegram?(sent) || !channels[:email][:deliver]

      Ticketing::Notifications::Deliver.email(**args, dedup_key: key.call("email"),
                                                      quiet: preference.quiet_now?, bucket: channels[:email][:bucket])
    end

    private

    def content(decision)
      ticket = decision.workflow.ticket
      reasons = Array(decision.evidence["reasons"]).uniq.map do |code|
        I18n.t("agents.stop_reason.plan_reasons.#{code}", default: code.humanize)
      end
      Ticketing::Notifications::Content.new(
        title: I18n.t("agents.supporter.plan_warning.title", code: ticket.code, risk: decision.risk_score),
        body: I18n.t("agents.supporter.plan_warning.body", title: ticket.title, reasons: reasons.join("; ")),
        url: Rails.application.routes.url_helpers.member_ticket_path(ticket)
      )
    end
  end
end
