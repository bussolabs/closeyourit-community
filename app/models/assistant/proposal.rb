# frozen_string_literal: true

module Assistant
  # An action proposed by the assistant: the model only writes this row, the user's click runs the
  # action (CYRA-907). `running` is the atomic claim that stops a double confirmation.
  class Proposal < ApplicationRecord
    belongs_to :message, class_name: "Assistant::Message", inverse_of: :proposals, optional: true
    # A Puck run is the other possible parent; the database allows exactly one (CYRA-1010).
    belongs_to :coworkers_run, class_name: "Coworkers::Run", optional: true, inverse_of: :action_proposals
    belongs_to :coworkers_rule, class_name: "Coworkers::Rule", optional: true
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :account, class_name: "Accounts::Account"

    enum :kind, { create_ticket: 0, comment_ticket: 1, change_ticket_status: 2, change_ticket_priority: 3,
                  assign_ticket: 4, create_todo: 5, create_idea: 6,
                  # A Puck hands a ticket to the existing automation, which opens the pull request (CYRA-1028).
                  start_agent_work: 7,
                  # A Puck wants to act in a connected app; the person's click runs the MCP call (CYRA-1014).
                  external_tool: 8 }, prefix: :kind
    enum :status, { pending: 0, running: 1, confirmed: 2, discarded: 3, failed: 4 }, prefix: :status

    # Kinds only a Puck proposes: the assistant's conversation never replays them (CYRA-1028, CYRA-1014).
    PUCK_ONLY_KINDS = %w[start_agent_work external_tool].freeze

    validates :payload, presence: true
    validates :origin, inclusion: { in: %w[user rule] }
    validate :exactly_one_parent
    validate :organization_matches_message

    scope :chronological, -> { order(:created_at, :id) }

    # A Puck's "waiting for your decision" notice stops asking once someone decided, on any channel.
    after_update_commit :settle_decision_notice, if: -> { coworkers_run_id && saved_change_to_status? && (status_confirmed? || status_discarded?) }

    def confirmable? = status_pending? || status_failed?

    private

    def settle_decision_notice
      Alerting::Notification.where(event_type: :puck_decision_needed, read_at: nil)
        .where("dedup_key LIKE ?", "puck_decision:#{id}:%").update_all(read_at: Time.current)
    end

    def exactly_one_parent
      errors.add(:base, :invalid) unless [ message_id, coworkers_run_id ].compact.size == 1
    end

    def organization_matches_message
      parent_organization_id = message&.organization_id || coworkers_run&.puck&.organization_id
      return if parent_organization_id.nil? || parent_organization_id == organization_id

      errors.add(:organization, :invalid)
    end
  end
end
