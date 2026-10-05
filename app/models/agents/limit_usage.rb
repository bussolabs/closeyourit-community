# frozen_string_literal: true

module Agents
  # Contatore giornaliero UTC di una policy. Viene letto e incrementato soltanto mentre la policy è
  # bloccata FOR UPDATE, quindi host diversi non possono superare il budget con un check-then-write.
  class LimitUsage < ApplicationRecord
    belongs_to :policy, class_name: "Agents::LimitPolicy", inverse_of: :usages

    validates :period_on, presence: true, uniqueness: { scope: :policy_id }
    validates :runs, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :cost, numericality: { greater_than_or_equal_to: 0 }
  end
end
