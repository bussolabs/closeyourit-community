# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1292 — leaves to a person a delivery whose repository declares no required checks, or whose pull
    # request did not pass every declared one.
    class RequiredChecksGate < DeliveryGate
      ACTION_STOPPED = "delivery_checks_stopped"
      ACTION_WOULD_STOP = "delivery_checks_would_stop"

      private

      def client = @client ||= Github::Client.new

      # An unreadable file is not a declared one: switched on it goes to a person, in a dry run it says nothing.
      def read_verdict
        config = client.repository_file(@candidate.repository.github_installation_id, @candidate.repository_full_name,
                                        RequiredChecks::PATH, ref: @candidate.base_ref.presence || "main")
        RequiredChecks.call(config:, checks: @candidate.checks_payload)
      rescue Github::Client::Error
        enforcing? ? RequiredChecks.unreadable : nil
      end

      def record!(verdict)
        record_event!(enforcing? ? ACTION_STOPPED : ACTION_WOULD_STOP, verdict.to_h) if verdict.review?
      end
    end
  end
end
