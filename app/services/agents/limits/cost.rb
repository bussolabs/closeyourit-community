# frozen_string_literal: true

module Agents
  module Limits
    # Canonicalizzazione unica dei costi prima che entrino in una firma o in una colonna numeric.
    # Nil significa "stima non disponibile" e resta distinto da zero in tutto il contratto.
    class Cost
      class << self
        def parse(value)
          return nil if value.nil?

          parsed = BigDecimal(value.to_s, exception: false)
          return unless parsed&.finite? && !parsed.negative? && parsed <= Agents::LimitPolicy::MAX_COST

          canonical = parsed.round(Agents::LimitPolicy::COST_SCALE)
          canonical if canonical == parsed
        end

        def dump(value)
          parse(value)&.to_s("F")
        end
      end
    end
  end
end
