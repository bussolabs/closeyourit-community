module Coworkers
  # What a Puck may do with one kind of action: allow, ask or deny (CYRA-1017).
  class Rule < ApplicationRecord
    self.table_name = "coworkers_rules"
    DECISIONS = %w[allow ask deny].freeze

    belongs_to :puck, class_name: "Coworkers::Puck"
    validates :action, inclusion: { in: ->(_) { Assistant::Proposal.kinds.keys } }, uniqueness: { scope: :puck_id }
    validates :decision, inclusion: { in: DECISIONS }
  end
end
