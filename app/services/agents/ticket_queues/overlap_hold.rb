# frozen_string_literal: true

module Agents
  module TicketQueues
    # CYAU-299 — the queue skips a ticket whose next phase writes to the repository and whose approved plan
    # names a file another ticket of the same project is changing right now (a live lease and a running
    # attempt that reported it). It comes back by itself when that work ends: a conflict avoided is cheaper
    # than one resolved. One SQL decides.
    module OverlapHold
      module_function

      # A condition on the queue's outer row (ticketing_tickets + agents_workflows), true when it may run.
      def sql(project:, now:)
        <<~SQL.squish
          (#{ready_phase_sql}) NOT IN (#{write_phases})
          OR NOT EXISTS (
            SELECT 1 FROM agents_plans AS held_plans
            CROSS JOIN LATERAL jsonb_path_query(held_plans.content, '$.work_items[*].files[*].path') AS planned(path)
            #{busy_joins(project:, now:)}
            WHERE held_plans.id = agents_workflows.frozen_plan_id
              AND busy_tickets.id <> ticketing_tickets.id
          )
        SQL
      end

      def busy_joins(project:, now:)
        connection = ActiveRecord::Base.connection
        <<~SQL.squish
          INNER JOIN agents_attempt_live_events AS busy_events
            ON busy_events.kind = 'file_change' AND busy_events.payload -> 'path' = planned.path
          INNER JOIN agents_attempts AS busy_attempts
            ON busy_attempts.id = busy_events.attempt_id AND busy_attempts.status = #{Agents::Attempt.statuses.fetch("running")}
          INNER JOIN agents_workflows AS busy_workflows ON busy_workflows.id = busy_attempts.workflow_id
          INNER JOIN ticketing_tickets AS busy_tickets
            ON busy_tickets.id = busy_workflows.ticket_id AND busy_tickets.project_id = #{connection.quote(project.id)}
          INNER JOIN agents_leases AS busy_leases
            ON busy_leases.ticket_id = busy_tickets.id AND busy_leases.expires_at > #{connection.quote(now)}
        SQL
      end

      def write_phases
        phases = Agents::PhaseProfile::PHASES.select { Agents::PhaseProfile.fetch(it).write_access? }
        phases.map { ActiveRecord::Base.connection.quote(it) }.join(", ")
      end

      def ready_phase_sql = Agents::Workflow::READY_EXECUTION_PHASE_SQL
    end
  end
end
