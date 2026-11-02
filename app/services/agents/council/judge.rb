# frozen_string_literal: true

module Agents
  module Council
    # A proposal passes when the other engine approves it and nobody flags a serious risk (CYRA-1133).
    # Pure: no database, no model output is trusted beyond the fixed lists.
    class Judge
      Verdict = Data.define(:proposal, :critique, :passed, :reasons)

      def self.call(proposals:, critiques:) = new(proposals, critiques).call

      def initialize(proposals, critiques)
        @proposals = Array(proposals).select { |p| p.is_a?(Hash) }.map { |p| p.to_h.deep_stringify_keys }
        @critiques = Array(critiques).select { |c| c.is_a?(Hash) }.map { |c| c.to_h.deep_stringify_keys }
      end

      def call
        kept.map do |proposal|
          critique = @critiques.find { |c| c["ref"] == proposal["ref"] && c["critic"] != proposal["proposer"] }
          reasons = reasons_for(proposal, critique)
          Verdict.new(proposal:, critique:, passed: reasons.empty?, reasons:)
        end
      end

      private

      def kept
        @proposals.select { |p| ENGINES.include?(p["proposer"]) }
                  .group_by { |p| p["proposer"] }
                  .flat_map { |_, list| list.first(MAX_PROPOSALS_PER_ENGINE) }
                  .map { |p| normalize(p) }
      end

      def normalize(proposal)
        engine = proposal["engine"].presence_in(ENGINES)
        proposal.merge("title" => proposal["title"].to_s.strip.truncate(255), "problem" => proposal["problem"].to_s.strip,
                       "solution" => proposal["solution"].to_s.strip, "kind" => proposal["kind"].presence_in(KINDS),
                       "risk" => proposal["risk"].presence_in(RISKS), "engine" => engine,
                       "model" => (proposal["model"] if engine && MODELS.fetch(engine).include?(proposal["model"])))
      end

      def reasons_for(proposal, critique)
        return [ "invalid" ] if proposal["title"].blank? || proposal["problem"].blank?
        return [ "no_vote" ] if critique.nil?
        return [ "serious_risk" ] if [ proposal["risk"], critique["risk"] ].include?("serious")
        return [ "rejected" ] unless critique["vote"] == "approve"

        []
      end
    end
  end
end
