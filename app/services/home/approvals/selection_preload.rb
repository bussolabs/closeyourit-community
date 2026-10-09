# frozen_string_literal: true

module Home
  module Approvals
    # What Home::Approvals::Detail reads to build its cards, read once for a whole selection instead of
    # once per key. The scopes are Detail's own, so a key outside them is simply missing: same anti-BOLA
    # gate, same nil card. A single key is a selection of one. CYRA-1048
    #
    #   SelectionPreload.new(account:, organization:, visible_tickets:, keys: ["review:…", "agent_plan:…"])
    class SelectionPreload
      attr_reader :resolver

      def initialize(account:, organization:, visible_tickets:, keys:)
        ids = keys.filter_map { |key| key.to_s.split(":", 2) }.group_by(&:first)
                  .transform_values { |pairs| pairs.map(&:last).compact }
        @tickets = review_tickets(visible_tickets, ids.fetch("review", []))
        @workflows = open_workflows(visible_tickets, ids.fetch("agent_plan", []))
        workflow_ids = @workflows.keys + @tickets.values.filter_map { |ticket| ticket.agent_workflow&.id }
        load_workflow_facts(workflow_ids)
        @account = account
        @organization = organization
        @resolver = Authorization::Resolver.new(account: account, organization: organization)
      end

      def ticket(id) = @tickets[id.to_s.downcase]
      def workflow(id) = @workflows[id.to_s.downcase]
      def failed_phases(workflow) = @failed[workflow.id]
      def open_phases(workflow) = @open[workflow.id]
      def asking?(workflow) = @asking.include?(workflow.id)
      def delivery_attempt(workflow) = @deliveries[workflow.id]
      def latest_plan(workflow) = @plans[workflow.id]
      def last_review_failure(workflow) = @review_failures[workflow.id]

      def role
        return @role if defined?(@role)

        @role = @organization.memberships.find_by(account: @account)&.role
      end

      private

      # strict_loading(false): each of these records then goes through the single-card approval, which
      # reads its own associations one record at a time on purpose (see BulkApprove#approve).
      def review_tickets(visible_tickets, ids)
        return {} if ids.empty?

        visible_tickets.strict_loading(false)
                       .includes(:project, :status, :current_work_report, agent_workflow: :review_candidate)
                       .where(id: ids).index_by(&:id)
      end

      # Workflows still open on a visible ticket: the same gate Detail#agent_plan_card had with find_by.
      def open_workflows(visible_tickets, ids)
        return {} if ids.empty?

        Agents::Workflow.strict_loading(false)
                        .where(ticket_id: visible_tickets.select(:id), cancelled_at: nil, completed_at: nil)
                        .includes(:review_candidate,
                                  ticket: [ :status, :current_work_report, { project: [ :cto, { organization: :cto } ] } ])
                        .where(id: ids).index_by(&:id)
      end

      def load_workflow_facts(workflow_ids)
        @failed = Agents::Workflows::PhaseResolver.failed_phases_by_workflow(workflow_ids)
        @open = Agents::Workflows::PhaseResolver.open_phases_by_workflow(workflow_ids)
        @asking = Agents::Clarification.where(workflow_id: workflow_ids, answered_at: nil).distinct.pluck(:workflow_id).to_set
        @deliveries = latest_deliveries(workflow_ids)
        @plans = latest_plans(@workflows.keys)
        @review_failures = last_review_failures(@workflows.keys)
      end

      # The attempt the review rejected last, per workflow: a stopped row's reason, read once for a
      # selection of blocked rows. CYRA-1060
      def last_review_failures(workflow_ids)
        return {} if workflow_ids.empty?

        Agents::Attempt.status_review_failed.includes(:host).where(workflow_id: workflow_ids)
                       .order(:started_at).group_by(&:workflow_id).transform_values(&:last)
      end

      # strict_loading(false) for the same reason as the tickets: the page renders the plan's own
      # associations, as it did when the plan came from a single-record read.
      def latest_plans(workflow_ids)
        return {} if workflow_ids.empty?

        Agents::Plan.strict_loading(false).where(workflow_id: workflow_ids)
                    .select("DISTINCT ON (agents_plans.workflow_id) agents_plans.*")
                    .reorder(:workflow_id, version: :desc).index_by(&:workflow_id)
      end

      # The last approved autopilot attempt that carries a work report, per workflow: the batch twin of
      # the single lookup Detail used to run for each card.
      def latest_deliveries(workflow_ids)
        return {} if workflow_ids.empty?

        Agents::Attempt.where(workflow_id: workflow_ids, phase: "autopilot", status: :approved)
                       .where("result ? 'work_report'").order(:finished_at, :created_at)
                       .group_by(&:workflow_id).transform_values(&:last)
      end
    end
  end
end
