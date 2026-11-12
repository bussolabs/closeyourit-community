# frozen_string_literal: true

module Agents
  module Supporters
    # CYRA-1293 — the floor the triage puts under every later score. Triage reads the ticket first: when it says
    # high risk, or asks for a person, the supporter never decides alone. The project chooses: off ignores it,
    # a dry run only writes it in the decision's evidence, on passes it to RiskScore as the previous score.
    class TriageRisk
      MODE_OFF = "off"
      MODE_DRY_RUN = "dry_run"
      MODE_ON = "on"
      MODES = [ MODE_OFF, MODE_DRY_RUN, MODE_ON ].freeze

      # High risk lands past the autonomous range; medium stays inside it, above an ordinary change.
      HIGH_FLOOR = RiskScore::SENSITIVE_PATH
      MEDIUM_FLOOR = 4

      Reading = Data.define(:floor, :mode) do
        # What RiskScore receives as the previous score: the floor only when the project switched it on.
        def applied = mode == MODE_ON ? floor : nil
        def stops? = applied.present? && !RiskScore.autonomous?(applied)
        def evidence = floor ? { "triage_floor" => floor, "triage_floor_mode" => mode } : {}
      end

      def self.for(workflow) = new(workflow).reading

      def initialize(workflow)
        @workflow = workflow
      end

      def reading
        mode = @workflow.ticket.project.triage_risk_floor_mode
        Reading.new(floor: mode == MODE_OFF ? nil : floor, mode:)
      end

      private

      def floor
        result = triage_result
        return HIGH_FLOOR if result["requires_human_approval"] == true || result["risk"] == "high"

        MEDIUM_FLOOR if result["risk"] == "medium"
      end

      # The newest triage that delivered a result: a failed or abandoned one says nothing about the ticket.
      def triage_result
        @workflow.attempts.where(phase: "triage").order(created_at: :desc)
                 .filter_map { |attempt| attempt.result.presence }.first.to_h
      end
    end
  end
end
