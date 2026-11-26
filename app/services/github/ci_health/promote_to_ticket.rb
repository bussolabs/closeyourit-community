# frozen_string_literal: true

module Github
  class CiHealth
    # Opens a ticket from a flaky CI job (CYRA-1164), with its figures, its latest flaky commits and a
    # ready scenario.
    # Observability::PromoteToTicket serialises double clicks; the job counts as promoted only while
    # its ticket is open (Github::CiJob#promoted?), so a closed ticket lets a new one be opened.
    class PromoteToTicket < Observability::PromoteToTicket
      def initialize(row:, reporter:, true_actor: nil)
        @row = row
        super(group: row.ci_job, reporter:, true_actor:)
      end

      private

      def already_promoted_code = "R422-GITHUB-CI-001"

      def ticket_params
        {
          project_id: @group.project.id,
          title: I18n.t("github.ci_health.ticket.title", job: @group.name).truncate(255),
          description: I18n.t("github.ci_health.ticket.description", job: @group.name, flaky: percent(@row.flaky_rate),
                                                                     days: CiHealth::WINDOW.in_days.to_i),
          technical_analysis: technical_details,
          scenarios_attributes: [ {
            step_given: I18n.t("github.ci_health.ticket.given", job: @group.name),
            step_when: I18n.t("github.ci_health.ticket.when"),
            step_then: I18n.t("github.ci_health.ticket.then", flaky: percent(@row.flaky_rate)),
            step_expected: I18n.t("github.ci_health.ticket.expected")
          } ],
          status_id: default_status&.id,
          priority_id: default_priority&.id
        }
      end

      def technical_details
        [
          "Job: #{@group.name}",
          "Repository: #{@group.repository.full_name}",
          "Finished runs in the last #{CiHealth::WINDOW.in_days.to_i} days: #{@row.runs}",
          "Failures: #{@row.failures} (#{percent(@row.failure_rate)})",
          "Flaky commits: #{@row.flaky_commits} (#{percent(@row.flaky_rate)})",
          "Flaky in the #{CiHealth::WINDOW.in_days.to_i} days before: #{percent(@row.previous_flaky_rate)}",
          "Latest flaky commits: #{@row.recent_flaky_shas.join(", ")}",
          "Average duration: #{seconds(@row.avg_duration)}",
          "Average queue wait: #{seconds(@row.avg_queue)}"
        ].join("\n").truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
      end

      def percent(rate) = rate.nil? ? "-" : "#{(rate * 100).round}%"
      def seconds(value) = value.nil? ? "-" : "#{value.round}s"
    end
  end
end
