# frozen_string_literal: true

module Alerting
  # An alert posted by the Slack app with its three buttons: where it lives in Slack and what people did
  # from it. Every change bumps `version`; Alerting::SlackRefreshJob writes the newest one back. CYRA-1156
  class SlackMessage < ApplicationRecord
    self.table_name = "alerting_slack_messages"

    MUTE_FOR = 1.hour

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :channel, class_name: "Alerting::Channel", inverse_of: :slack_messages
    belongs_to :rule, class_name: "Alerting::Rule", optional: true
    belongs_to :project, class_name: "Projects::Project", optional: true
    belongs_to :subject, polymorphic: true, optional: true
    belongs_to :claimed_by, class_name: "Accounts::Account", optional: true
    belongs_to :muted_by, class_name: "Accounts::Account", optional: true
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true
    belongs_to :ticket_opened_by, class_name: "Accounts::Account", optional: true

    enum :status, { open: 0, recovered: 1 }, prefix: :status

    validates :event_type, :subject_type, :subject_id, :slack_channel, :slack_ts, :title, presence: true

    scope :for_subject, ->(subject) { where(subject_type: subject.class.name, subject_id: subject.id) }

    def muted? = muted_until.present? && muted_until > Time.current

    # Applies the change under a row lock and bumps the version; only a real change queues a refresh.
    def change!(attributes)
      applied = with_lock do
        assign_attributes(attributes)
        next false unless changed?

        self.version += 1
        save!
      end
      SlackRefreshJob.perform_later(id, version) if applied
      applied
    end
  end
end
