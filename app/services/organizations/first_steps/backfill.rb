# frozen_string_literal: true

module Organizations
  module FirstSteps
    # Rebuilds the first steps from the data already there, oldest date found (CYRA-1159). Runs once,
    # in its own data migration; insert if absent, so a step already written keeps its day and a second
    # run changes nothing. Default alert rules never count: every organization gets them at birth.
    class Backfill < ApplicationService
      def call
        sources.each { |step, select| backfill(step, select) }
        Result.ok(nil)
      end

      private

      def sources
        {
          "first_error" => <<~SQL,
            SELECT projects.organization_id, MIN(errors_groups.first_seen_at)
            FROM errors_groups JOIN projects ON projects.id = errors_groups.project_id
            WHERE errors_groups.first_seen_at IS NOT NULL GROUP BY projects.organization_id
          SQL
          "alert_rule" => <<~SQL,
            SELECT alerting_rules.organization_id, MIN(alerting_rules.created_at)
            FROM alerting_rules WHERE (alerting_rules.event_type, alerting_rules.name) NOT IN (#{default_rules})
            GROUP BY alerting_rules.organization_id
          SQL
          "invitation" => <<~SQL,
            SELECT organization_id, MIN(created_at) FROM connections_invitations GROUP BY organization_id
          SQL
          "telegram" => <<~SQL,
            SELECT organization_id, MIN(linked_at) FROM (
              SELECT connections_memberships.organization_id,
                     GREATEST(accounts.telegram_linked_at, connections_memberships.created_at) AS linked_at
              FROM connections_memberships JOIN accounts ON accounts.id = connections_memberships.account_id
              WHERE accounts.telegram_linked_at IS NOT NULL
              UNION ALL
              SELECT organization_id, created_at FROM alerting_telegram_groups
            ) linked GROUP BY organization_id
          SQL
          "ticket_closed" => <<~SQL
            SELECT projects.organization_id, MIN(ticketing_tickets.closed_at)
            FROM ticketing_tickets JOIN projects ON projects.id = ticketing_tickets.project_id
            WHERE ticketing_tickets.closed_at IS NOT NULL GROUP BY projects.organization_id
          SQL
        }
      end

      def backfill(step, select)
        FirstStep.connection.exec_update(<<~SQL.squish, "Organizations::FirstSteps::Backfill", [ step ])
          INSERT INTO organization_first_steps (organization_id, step, reached_at, created_at)
          SELECT found.organization_id, CAST($1 AS varchar), found.reached_at, CURRENT_TIMESTAMP
          FROM (#{select}) AS found (organization_id, reached_at)
          ON CONFLICT (organization_id, step) DO NOTHING
        SQL
      end

      # The pairs Alerting::Rules::InstallDefaults writes, as a VALUES list of (event_type, name).
      def default_rules
        pairs = Alerting::Rules::InstallDefaults::DEFAULTS.map do |default|
          FirstStep.sanitize_sql_array([ "(?, ?)", Alerting::Rule.event_types.fetch(default[:event_type].to_s), default[:name] ])
        end
        "VALUES #{pairs.join(', ')}"
      end
    end
  end
end
