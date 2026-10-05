# frozen_string_literal: true

module Crashes
  class Report < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project", inverse_of: :crash_reports
    has_many :attachments, class_name: "Crashes::Attachment", foreign_key: :report_id, dependent: :delete_all, inverse_of: :report
    scope :linked, -> { where("EXISTS (SELECT 1 FROM errors_events WHERE project_id = crashes_reports.project_id AND event_id = crashes_reports.event_id) OR EXISTS (SELECT 1 FROM errors_ingest_payloads WHERE project_id = crashes_reports.project_id AND payload->>'event_id' = crashes_reports.event_id)") }

    validates :event_id, format: { with: EVENT_ID }
  end
end
