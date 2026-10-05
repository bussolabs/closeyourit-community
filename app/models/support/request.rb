# frozen_string_literal: true

module Support
  # A support request sent from the footer (CYRA-935), with the details that help reproduce it.
  class Request < ApplicationRecord
    include LengthBudget

    self.table_name = "support_requests"

    belongs_to :account, class_name: "Accounts::Account"
    belongs_to :organization, class_name: "Organizations::Organization", optional: true
    belongs_to :handled_by, class_name: "Accounts::Account", optional: true

    normalizes :body, with: ->(value) { LengthBudget.normalize_newlines(value).strip }

    validates :body, presence: true
    length_budget :body, maximum: Support::Constants::BODY_MAX_CHARS

    scope :pending, -> { where(handled_at: nil) }

    def handled? = handled_at.present?
  end
end
