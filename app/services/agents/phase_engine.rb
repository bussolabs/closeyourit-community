# frozen_string_literal: true

module Agents
  # CYRA-1301 — the engine and model a project chose for its light phases (triage and the two releases), when
  # this machine can run them. The plan and the code stay on the machine's engine. The reviewer is always the
  # other engine: the choice never weakens the cross review.
  module PhaseEngine
    LIGHT_PHASES = %w[triage closer_staging closer_production].freeze
    OPTIONS = Council::ENGINES.flat_map { |engine| Council::MODELS.fetch(engine).map { |model| "#{engine}:#{model}" } }.freeze

    def self.choice_for(phase:, project:, host:)
      return nil unless LIGHT_PHASES.include?(phase)

      engine, model = project.light_phase_engine.to_s.split(":", 2)
      return nil unless OPTIONS.include?("#{engine}:#{model}") && Council::WorkChoice.installed?(host, engine)

      Council::WorkChoice::Choice.new(engine:, model:, reviewer: (Council::ENGINES - [ engine ]).first)
    end
  end
end
