# frozen_string_literal: true

module Ai
  # Tokens one organization spent on AI chat in one calendar month (CYRA-914), for the monthly cap.
  class UsageMonth < ApplicationRecord
    self.table_name = "ai_usage_months"

    belongs_to :organization, class_name: "Organizations::Organization"
  end
end
