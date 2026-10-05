# frozen_string_literal: true

class CrashReportSerializer < ApplicationSerializer
  attributes :id, :project_id, :event_id, :release, :environment, :dist, :manifest, :created_at
  attribute :attachments do |report|
    report.attachments.sort_by { |attachment| [ attachment.created_at, attachment.id ] }.map do |attachment|
      { id: attachment.id, filename: attachment.filename, kind: attachment.kind,
        byte_size: attachment.blob.byte_size, sha256: attachment.blob.sha256,
        download_path: "/api/v1/crashes/attachments/#{attachment.id}/download" }
    end
  end
end
