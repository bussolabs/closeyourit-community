module Coworkers
  # Steps a person showed a Puck once, saved so it can repeat them (CYRA-1013).
  class Procedure < ApplicationRecord
    self.table_name = "coworkers_procedures"
    belongs_to :puck, class_name: "Coworkers::Puck"
    belongs_to :created_by, class_name: "Accounts::Account"
    validates :name, presence: true, length: { maximum: 120 }
    validates :steps, presence: true, length: { maximum: 8000 }
  end
end
