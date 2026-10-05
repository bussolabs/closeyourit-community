# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::Symbolication::Native::ReportRead do
  let(:project) { create(:project) }

  def occurrence(owner = project)
    create(:error_event, project: owner, group: create(:error_group, project: owner), payload: { "platform" => "native" })
  end

  def report(event, manifest = { "threads" => [] })
    event.project.crash_reports.create!(event_id: event.event_id, manifest: manifest)
  end

  it "returns no reports for no visible events" do
    expect(described_class.call(project: project, events: [])).to eq({})
  end

  it "scopes before measuring and batch reads only retained event reports" do
    first, second = occurrence, occurrence
    report(first)
    report(second)
    foreign = occurrence(create(:project))
    report(foreign, { "oversized" => "x" * 6.megabytes })
    statements = []
    listener = ->(_name, _start, _finish, _id, data) { statements << data[:sql] if data[:sql].include?("bounded_native_manifest") }
    value = nil
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      value = described_class.call(project: project, events: [ first, second, foreign ])
    end
    expect(value.keys).to match_array([ first.event_id, second.event_id ])
    expect(statements.size).to eq(1)
    project.crash_reports.where(event_id: first.event_id).update_all(created_at: 31.days.ago)
    expect(described_class.call(project: project, events: [ first, second ]).keys).to eq([ second.event_id ])
  end

  it "rejects the combined byte budget before returning manifests" do
    first, second = occurrence, occurrence
    [ first, second ].each { |event| report(event, { "large" => "x" * 3.megabytes }) }
    expect { described_class.call(project: project, events: [ first, second ]) }.to raise_error(Artifacts::Rejected, "native_source_budget")
  end
end
