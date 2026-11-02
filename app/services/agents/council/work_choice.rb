# frozen_string_literal: true

module Agents
  module Council
    # The engine and model the council chose for its ticket, when this machine can run them (CYRA-1133).
    # The reviewer is always the other engine: the choice never weakens the cross review.
    module WorkChoice
      Choice = Data.define(:engine, :model, :reviewer)

      def self.for(ticket:, host:)
        proposal = CouncilProposal.find_by(ticket_id: ticket.id)
        engine = proposal&.suggested_engine
        return nil unless ENGINES.include?(engine) && installed?(host, engine)

        model = proposal.suggested_model if MODELS.fetch(engine).include?(proposal.suggested_model)
        Choice.new(engine:, model:, reviewer: (ENGINES - [ engine ]).first)
      end

      def self.installed?(host, engine)
        Array(host.runtimes).any? { |r| r.is_a?(Hash) && r["present"] == true && r["name"] == engine }
      end
    end
  end
end
