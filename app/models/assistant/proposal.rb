# frozen_string_literal: true

module Assistant
  # An action proposed by the assistant: the model only writes this row, the user's click runs the
  # action (CYRA-907). `running` is the atomic claim that stops a double confirmation.
  class Proposal < ApplicationRecord
    belongs_to :message, class_name: "Assistant::Message", inverse_of: :proposals
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :account, class_name: "Accounts::Account"

    enum :kind, { create_ticket: 0, comment_ticket: 1, change_ticket_status: 2, change_ticket_priority: 3,
                  assign_ticket: 4, create_todo: 5, create_idea: 6 }, prefix: :kind
    enum :status, { pending: 0, running: 1, confirmed: 2, discarded: 3, failed: 4 }, prefix: :status

    validates :payload, presence: true
    validate :organization_matches_message

    scope :chronological, -> { order(:created_at, :id) }

    def confirmable? = status_pending? || status_failed?

    private

    def organization_matches_message
      return if message.nil? || message.organization_id == organization_id

      errors.add(:organization, :invalid)
    end
  end
end
