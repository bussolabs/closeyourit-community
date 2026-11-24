# frozen_string_literal: true

module Agents
  # CYRA-1327 — a run that started over because its attempts ran out works on the engine written on it
  # (`budget_restart_engine`), not on the machine's usual one: the same engine on the same ticket fails
  # the same way, so the second run is a different reader. Same shape as the council's choice, and the
  # reviewer is still the other engine, unless the machine reports it out of quota (CYRA-1360).
  #
  # It is asked BEFORE the council's own choice in Claim#ensure_attempt!, because the engine the
  # council picked is exactly the one that has just run out of attempts on this ticket. It comes after
  # the conflict resolution, which is a need of one phase and not of the whole run.
  #
  # A machine without the other engine installed keeps its usual one: the restart happens anyway, once,
  # because what counts the runs is the column being written, not the engine actually used.
  module BudgetRestart
    def self.choice_for(workflow:, host:)
      engine = workflow.budget_restart_engine.presence
      return nil unless Council::ENGINES.include?(engine) && Council::WorkChoice.available?(host, engine)

      Council::WorkChoice::Choice.new(engine: engine, model: nil, reviewer: Council::WorkChoice.reviewer_for(host, engine))
    end
  end
end
