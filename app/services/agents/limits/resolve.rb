# frozen_string_literal: true

module Agents
  module Limits
    # Risolve tutti i livelli applicabili e produce il contratto flat letto dall'Automator. Per ogni
    # soglia il minimo è autoritativo; il kill switch è vero se lo impone anche un solo livello.
    class Resolve < ApplicationService
      DEFAULT_MAX_AGE_SECONDS = 60

      def initialize(organization:, project: nil, runtime: nil)
        @organization = organization
        @project = project
        @runtime = runtime.to_s.strip.downcase.presence
      end

      def call
        policies = Agents::LimitPolicy.applicable_to(organization: @organization, project: @project, runtime: @runtime)
                                      .to_a
        {
          scope: policies.any?(&:project_id) ? "repository" : "organization",
          max_parallel: minimum(policies, :max_parallel),
          max_daily_runs: minimum(policies, :max_daily_runs),
          max_daily_cost: minimum(policies, :max_daily_cost)&.to_f,
          max_runtime_seconds: minimum(policies, :max_runtime_seconds),
          stop_dispatch: policies.any?(&:stop_dispatch?),
          max_age_seconds: minimum(policies, :max_age_seconds) || DEFAULT_MAX_AGE_SECONDS
        }.compact
      end

      private

      def minimum(policies, attribute)
        policies.filter_map { |policy| policy.public_send(attribute) }.min
      end
    end
  end
end
