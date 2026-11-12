# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1292 — which checks a repository declares as required, and whether the pull request passed them all.
    # The list is read from the default branch, where a work branch cannot change it. No version 2 file, or an
    # empty list: nothing says which checks count, so "none red" proves nothing and a person decides.
    class RequiredChecks
      PATH = ".closeyourit/quality-gate.yml"
      PINNED_VERSION = 2
      PASSED = "SUCCESS"

      Verdict = Data.define(:reasons, :declared, :missing) do
        def review? = reasons.any?
        def to_h = { reasons:, declared:, missing: }
      end

      def self.call(...) = new(...).call

      # What an unreadable file amounts to: nothing declared.
      def self.unreadable = new(config: nil, checks: []).call

      def initialize(config:, checks:)
        @config = config
        @checks = Array(checks).select { |check| check.is_a?(Hash) }
      end

      def call
        return Verdict.new(reasons: %w[required_checks_undeclared], declared: [], missing: []) if declared.empty?

        Verdict.new(reasons: missing.any? ? %w[required_checks_missing] : [], declared:, missing:)
      end

      private

      def declared
        @declared ||= begin
          data = parsed
          pinned = data["version"] == PINNED_VERSION && data["remote"].is_a?(Hash)
          pinned ? Array(data.dig("remote", "required_checks")).map(&:to_s).compact_blank : []
        end
      end

      # Plain data only: the file comes from a repository, never a trusted source of objects.
      def parsed
        data = YAML.safe_load(@config.to_s)
        data.is_a?(Hash) ? data : {}
      rescue Psych::Exception
        {}
      end

      def missing = @missing ||= declared.reject { |name| passed.include?(name) }

      # A modern check carries a name and a conclusion, an older status a context and a state.
      def passed
        @passed ||= @checks.filter_map do |check|
          verdict = check["conclusion"].presence || check["state"]
          (check["name"].presence || check["context"].presence) if verdict.to_s.upcase == PASSED
        end
      end
    end
  end
end
