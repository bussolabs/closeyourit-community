# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Read do
  it "rejects oversized derived data in the same SQL snapshot before returning its JSON" do
    project = create(:project)
    event = Errors::Ingest::Record.call(project: project, payload: { "event_id" => "c" * 32, "message" => "failure" }).value
    Errors::Symbolication.create!(project_id: project.id, event_id: event.id, event_created_at: event.created_at,
      result: { "frames" => [], "large" => "x" * 5.megabytes })
    statements = []
    listener = ->(_name, _start, _finish, _id, data) { statements << data[:sql] if data[:sql].include?("bounded_result") }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      expect { described_class.call(events: [ event ]) }.to raise_error(Artifacts::Rejected, "symbolication_response_budget")
    end
    expect(statements.size).to eq(1)
    expect(statements.first).to include("CASE WHEN total_bytes", "SUM(octet_length(result::text)) OVER ()")
  end
end
