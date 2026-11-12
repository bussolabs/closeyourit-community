# frozen_string_literal: true

module Agents
  module Numbers
    # CYRA-1296 — the numbers of the automatic round per project, over a window: how much it does alone, how often it is
    # right the first time, how long and how much a ticket takes, how many releases broke something.
    # Read-only, one grouped query per number: the cost does not grow with the projects.
    class PerProject
      PRODUCTION = "production"
      CODE_PHASE = "autopilot"
      PLAN = "plan"
      APPROVED = "approved"
      # Every step a person can sign: a ticket is hands-off when none of them carries a name.
      PERSON_SIGNATURES = %i[approved_by_id autopilot_approved_by_id closer_production_approved_by_id].freeze
      PROJECT = "ticketing_tickets.project_id"

      Row = Data.define(:completed, :hands_off, :attempts, :first_pass, :plans_judged, :plans_approved,
                        :lead_seconds, :cost, :releases, :failed_releases) do
        def hands_off_rate = percent(hands_off, completed)
        def first_pass_rate = percent(first_pass, completed)
        def plans_approved_rate = percent(plans_approved, plans_judged)
        def failures_per_hundred = percent(failed_releases, releases)
        def attempts_per_ticket = completed.positive? ? (attempts.to_f / completed).round(1) : nil
        def cost_per_ticket = completed.positive? && cost ? (cost.to_f / completed).round(2) : nil
        def lead_hours = lead_seconds && (lead_seconds.to_f / 3600).round(1)

        private

        # nil when there is nothing to divide by: "no data" is not "zero".
        def percent(part, whole) = whole.positive? ? (part * 100.0 / whole).round : nil
      end

      def self.call(project_ids:, since:) = new(project_ids:, since:).call

      def initialize(project_ids:, since:)
        @project_ids = project_ids
        @since = since
      end

      def call
        @project_ids.index_with do |id|
          Row.new(completed: completed_counts[id].to_i, hands_off: hands_off[id].to_i, attempts: attempts[id].to_i,
                  first_pass: first_pass[id].to_i, plans_judged: plans.values_at([ id, APPROVED ], [ id, :other ]).sum(&:to_i),
                  plans_approved: plans[[ id, APPROVED ]].to_i, lead_seconds: lead[id], cost: cost[id],
                  releases: releases[id].to_i, failed_releases: failed_releases[id].to_i)
        end
      end

      private

      def completed
        Agents::Workflow.joins(:ticket).where(ticketing_tickets: { project_id: @project_ids })
                        .where(completed_at: @since..)
      end

      def completed_counts = @completed_counts ||= completed.group(PROJECT).count

      def hands_off = @hands_off ||= completed.where(PERSON_SIGNATURES.index_with { nil }).group(PROJECT).count

      def lead
        @lead ||= completed.group(PROJECT)
                           .average(Arel.sql("EXTRACT(EPOCH FROM agents_workflows.completed_at - agents_workflows.created_at)"))
      end

      def completed_attempts = Agents::Attempt.joins(workflow: :ticket).merge(completed)

      def attempts = @attempts ||= completed_attempts.group(PROJECT).count

      # Unpriced attempts carry no cost: a project with none answers nil, not zero.
      def cost = @cost ||= completed_attempts.where.not(cost_usd: nil).group(PROJECT).sum(:cost_usd)

      def first_pass
        code_runs = Agents::Attempt.where(phase: CODE_PHASE)
                                   .where(Agents::Attempt.arel_table[:workflow_id].eq(Agents::Workflow.arel_table[:id]))
                                   .select(Arel.star.count)
        @first_pass ||= completed.where("(#{code_runs.to_sql}) = 1").group(PROJECT).count
      end

      # Keyed [project, "approved"] and [project, :other]: every other verdict on a plan is a plan not approved.
      def plans
        @plans ||= Agents::SupporterDecision.joins(workflow: :ticket)
                                            .where(ticketing_tickets: { project_id: @project_ids })
                                            .where(target_type: PLAN, created_at: @since..)
                                            .group(PROJECT, :outcome).count
                                            .each_with_object(Hash.new(0)) do |((project, outcome), count), sums|
          sums[[ project, outcome == APPROVED ? APPROVED : :other ]] += count
        end
      end

      def production_releases
        Projects::Release.where(project_id: @project_ids, environment: PRODUCTION, created_at: @since..)
      end

      def releases = @releases ||= production_releases.group(:project_id).count

      # A release failed when an error of its project was first seen in it (CYRA-1295 reads the same link).
      def failed_releases
        groups = Errors::Group.arel_table
        table = Projects::Release.arel_table
        born_here = Errors::Group.where(groups[:project_id].eq(table[:project_id]))
                                 .where(groups[:first_seen_release].eq(table[:version]))
        @failed_releases ||= production_releases.where(born_here.arel.exists).group(:project_id).count
      end
    end
  end
end
