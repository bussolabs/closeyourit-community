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
        return nil unless ENGINES.include?(engine) && available?(host, engine)

        model = proposal.suggested_model if MODELS.fetch(engine).include?(proposal.suggested_model)
        Choice.new(engine:, model:, reviewer: (ENGINES - [ engine ]).first)
      end

      def self.installed?(host, engine)
        Array(host.runtimes).any? { |r| r.is_a?(Hash) && r["present"] == true && r["name"] == engine }
      end

      # Installed, and not reported out of quota by the machine: a chosen engine that cannot answer
      # leaves the phase to the machine's own engine (CYRA-1358).
      def self.available?(host, engine, now: Time.current)
        installed?(host, engine) && !quota_paused?(host, engine, now:)
      end

      def self.quota_paused?(host, engine, now:)
        Array(host.agent_quota).any? do |entry|
          next false unless entry.is_a?(Hash) && entry["runtime"] == engine

          until_time = Time.zone.parse(entry["paused_until"].to_s)
          until_time.present? && until_time > now
        rescue ArgumentError
          false
        end
      end
      private_class_method :quota_paused?
    end
  end
end
