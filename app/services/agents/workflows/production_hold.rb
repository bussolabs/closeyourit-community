# frozen_string_literal: true

module Agents
  module Workflows
    # The hold before production (CYRA-871): a release starts only once the wait after the staging check
    # is over, and never while a new, still open staging error appeared since. Resolving or ignoring
    # that error lifts the hold.
    #
    # The wait (CYRA-1000) is whole hours, picked on project, organization or platform: the closest
    # level wins, as for retention, else DEFAULT_HOURS. 0 skips the wait, never the error check. It is
    # read at check time and never stored, so a change applies at once to releases already waiting.
    #
    # Like ProductionLock, the predicate is SQL for the queue and Ruby for the claim, over one relation.
    class ProductionHold
      DEFAULT_HOURS = 2
      HOURS_RANGE = 0..72
      STAGING = "staging"

      # The project's wait in hours: nil inherits, 0 is a choice. Callers rendering many rows pass the
      # organization and the platform settings already loaded.
      def self.hours(project, organization: project.organization, global: Settings::Global.instance)
        [ project.production_hold_hours, organization&.production_hold_hours ].compact.first || platform_hours(global)
      end

      # What a blank organization inherits: the platform's choice, else the system value.
      def self.platform_hours(global = Settings::Global.instance) = global.production_hold_hours || DEFAULT_HOURS

      def self.window(...) = hours(...).hours

      # True when the hold is released, for the outer agents_workflows + ticketing_tickets row.
      # `window` is the project's: the queue runs on one project at a time.
      def self.released_sql(now:, window:)
        verified = if window.positive?
          ActiveRecord::Base.sanitize_sql_array([ "agents_workflows.closer_staging_verified_at <= ?", now - window ])
        else
          "agents_workflows.closer_staging_verified_at IS NOT NULL"
        end
        "#{verified} AND NOT #{staging_errors_sql}"
      end

      # True when a new, still open staging error appeared after the staging check.
      def self.staging_errors_sql
        errors = new_staging_errors(project: Ticketing::Ticket.arel_table[:project_id],
                                    since: Agents::Workflow.arel_table[:closer_staging_verified_at])
        "EXISTS (#{errors.select(1).to_sql})"
      end

      # Why production waits, or nil when the hold is released.
      def self.reason(workflow, now:)
        verified_at = workflow.closer_staging_verified_at
        return if verified_at.nil?

        wait = window(workflow.ticket.project)
        return { reason: "staging_soak", until: verified_at + wait } if soaking?(verified_at, now:, window: wait)

        group_id = new_staging_errors(project: workflow.ticket.project_id, since: verified_at)
                   .order(:first_seen_at).pick(:id)
        { reason: "staging_errors", error_group_id: group_id } if group_id
      end

      # With 0 hours there is no wait and no time to show: only the error check remains.
      def self.soaking?(verified_at, now:, window:)
        window.positive? && now < verified_at + window
      end

      # `project` and `since` are a column of the outer row (queue) or a value (claim).
      def self.new_staging_errors(project:, since:)
        groups = Errors::Group.arel_table
        events = Errors::Event.arel_table
        staging_events = Errors::Event.where(events[:group_id].eq(groups[:id]))
                                      .where(environment: STAGING)
                                      .where(events[:occurred_at].gteq(since))
        Errors::Group.status_unresolved
                     .where(groups[:project_id].eq(project))
                     .where(groups[:first_seen_at].gteq(since))
                     .where(staging_events.arel.exists)
      end
      private_class_method :new_staging_errors
    end
  end
end
