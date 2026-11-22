# frozen_string_literal: true

module Agents
  module Clarifications
    # CYRA-1339 — splits a comment written as "1. … 2. …" into one answer per question of the round.
    # Returns nil whenever the numbering does not name the round unambiguously: the caller then keeps
    # the comment as an answer to the whole round.
    module NumberedAnswers
      MARKER = /\A\s*(\d{1,2})[.)]\s+/

      def self.call(body:, count:)
        parts = {}
        current = nil
        body.to_s.each_line(chomp: true) do |line|
          if (match = line.match(MARKER))
            current = match[1].to_i
            return nil unless current.between?(1, count) && !parts.key?(current)

            parts[current] = [ line.sub(MARKER, "") ]
          else
            return nil if current.nil? && line.strip.present?

            parts[current] << line if current
          end
        end
        return nil if parts.empty?

        Array.new(count) { |index| parts[index + 1]&.join("\n")&.strip }
      end
    end
  end
end
