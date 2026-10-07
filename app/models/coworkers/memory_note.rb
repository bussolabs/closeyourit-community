module Coworkers
  # Something a Puck asked to remember. Every note the model writes waits for the owner: tickets,
  # logs and pages can carry instructions, so nothing it learns applies by itself (CYRA-1012).
  class MemoryNote < ApplicationRecord
    self.table_name = "coworkers_memory_notes"
    STATUSES = %w[pending active dismissed].freeze
    MAX_PENDING = 50
    MAX_ACTIVE = 30

    belongs_to :puck, class_name: "Coworkers::Puck"
    belongs_to :run, class_name: "Coworkers::Run", optional: true
    validates :body, presence: true, length: { maximum: 500 }
    validates :status, inclusion: { in: STATUSES }

    scope :pending, -> { where(status: "pending") }
    scope :active, -> { where(status: "active") }
  end
end
