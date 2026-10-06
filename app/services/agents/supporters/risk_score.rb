# frozen_string_literal: true

module Agents
  module Supporters
    # CYAU-235 — how risky a question or a plan is, from 1 to 10. Up to 6 the supporter may decide alone;
    # from 7 a person decides. The score only goes up: triage proposes it, the server raises it with fixed
    # rules that do not trust the model, and nothing lowers it again.
    module RiskScore
      RANGE = (1..10)
      AUTONOMOUS_MAX = 6
      RESERVED = 10
      SENSITIVE_PATH = 8
      # Database, release, CI and access code: a plan that touches them is never routine.
      SENSITIVE_PATHS = [
        %r{\Adb/}, %r{(\A|/)migrations?/}, %r{\A\.github/}, %r{\A\.gitlab-ci}, %r{\A\.kamal/},
        %r{\Aconfig/deploy}, %r{(\A|/)deploy/}, %r{(\A|/)Dockerfile}, %r{(\A|/)auth(/|_|\.|\z)},
        %r{\Aconfig/credentials}, %r{\Ascripts/release}
      ].freeze

      module_function

      # The score in force. An unreadable proposal counts as the highest risk.
      def resolve(previous:, proposed:, reserved: false, paths: [])
        scores = [ previous, readable(proposed) || RANGE.max ]
        scores << RESERVED if reserved
        scores << SENSITIVE_PATH if paths.any? { |path| sensitive?(path) }
        scores.compact.max
      end

      def autonomous?(score) = score.is_a?(Integer) && RANGE.cover?(score) && score <= AUTONOMOUS_MAX

      # The plan risk levels the score maps onto: the supporter approves up to medium.
      def risk_level(score)
        return "high" unless score.is_a?(Integer) && score <= AUTONOMOUS_MAX

        score <= 3 ? "low" : "medium"
      end

      def readable(score) = (score if score.is_a?(Integer) && RANGE.cover?(score))

      def sensitive?(path)
        clean = path.to_s.delete_prefix("./").delete_prefix("/")
        SENSITIVE_PATHS.any? { |pattern| clean.match?(pattern) }
      end
    end
  end
end
