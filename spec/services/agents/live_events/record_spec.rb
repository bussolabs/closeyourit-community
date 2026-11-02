# frozen_string_literal: true

require "rails_helper"

# CYAU-282 — the steps an agent takes while it works a ticket, sent by the machine that runs the attempt.
RSpec.describe Agents::LiveEvents::Record do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:workflow) { create(:agent_workflow, organization:, triage_started_at: Time.current) }
  let(:project) { workflow.ticket.project }
  let(:attempt) { create(:agent_attempt, workflow:, organization:, host:, phase: "triage", status: :running) }

  let(:hunks) { [ { "oldStart" => 1, "oldLines" => 3, "newStart" => 1, "newLines" => 4, "lines" => [ " a", "+b" ] } ] }
  let(:change) do
    { "seq" => 1, "at" => "2026-11-02T15:00:00Z",
      "event" => { "kind" => "file_change", "path" => "app/models/ticket.rb", "created" => false,
                   "added" => 1, "removed" => 0, "hunks" => hunks } }
  end

  def record(events, on: host, target: attempt)
    described_class.call(host: on, attempt: target, events:)
  end

  it "stores the steps and tells the machine how far it got and whether code is kept" do
    read = { "seq" => 2, "at" => "2026-11-02T15:00:01Z", "event" => { "kind" => "file_read", "path" => "a.rb" } }

    result = record([ change, read ])

    expect(result).to be_ok
    expect(result.value).to eq(accepted_through: 2, include_code: false)
    expect(attempt.live_events.order(:seq).pluck(:seq, :kind)).to eq([ [ 1, "file_change" ], [ 2, "file_read" ] ])
    expect(attempt.live_events.find_by(seq: 1)).to have_attributes(organization_id: organization.id,
                                                         recorded_at: Time.utc(2026, 11, 2, 15))
  end

  it "tells the open pages that the session moved, without sending what changed (CYRA-1138)" do
    allow(Realtime::ThrottledRefresh).to receive(:call)

    record([ change ])

    expect(Realtime::ThrottledRefresh).to have_received(:call).once
      .with(Realtime::Streams.automator_live_project(organization_id: organization.id, project_id: project.id),
            frame: Agents::LiveEvents::Broadcast::FRAME)
  end

  it "sends no signal for a batch that stores nothing" do
    allow(Realtime::ThrottledRefresh).to receive(:call)

    record([])

    expect(Realtime::ThrottledRefresh).not_to have_received(:call)
  end

  it "drops the code but keeps where it changed when the project has not turned the code view on (CYAU-299)" do
    record([ change ])

    expect(attempt.live_events.first.payload).to eq(
      "path" => "app/models/ticket.rb", "created" => false, "added" => 1, "removed" => 0,
      "hunks" => [ { "old_start" => 1, "old_lines" => 3, "new_start" => 1, "new_lines" => 4, "lines" => [] } ]
    )
  end

  it "keeps the code when the project has turned the code view on" do
    project.update!(automator_live_code_enabled: true)

    result = record([ change ])

    expect(result.value).to eq(accepted_through: 1, include_code: true)
    expect(attempt.live_events.first.payload["hunks"]).to eq(
      [ { "old_start" => 1, "old_lines" => 3, "new_start" => 1, "new_lines" => 4, "lines" => [ " a", "+b" ] } ]
    )
  end

  it "ignores a step already stored, so the machine can send a batch again" do
    record([ change ])
    again = change.deep_merge("event" => { "path" => "other.rb" })

    expect(record([ again ]).value).to eq(accepted_through: 1, include_code: false)
    expect(attempt.live_events.pluck(:payload).map { it["path"] }).to eq([ "app/models/ticket.rb" ])
  end

  it "records the marker of a machine queue that stopped at its limit" do
    record([ { "seq" => 7, "at" => "2026-11-02T15:00:00Z", "truncated" => true } ])

    expect(attempt.live_events.first).to have_attributes(seq: 7, kind: "truncated", payload: {})
  end

  it "keeps commands and searches as short text" do
    events = [
      { "seq" => 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "command", "command" => "bin/rspec …" } },
      { "seq" => 2, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "search", "pattern" => "with_status" } }
    ]

    record(events)

    expect(attempt.live_events.order(:seq).pluck(:payload)).to eq([ { "command" => "bin/rspec …" }, { "pattern" => "with_status" } ])
  end

  it "refuses a machine that is not running the attempt" do
    other = create(:agent_host, organization:)

    result = record([ change ], on: other)

    expect(result).to be_err
    expect(result.error.code).to eq("R409-LIVE-001")
    expect(attempt.live_events).to be_empty
  end

  it "refuses steps for an attempt that is over" do
    attempt.update!(status: :failed, failure_reason: "x", finished_at: Time.current)

    expect(record([ change ]).error.code).to eq("R409-LIVE-002")
  end

  describe "a batch out of shape is refused as a whole" do
    [
      [ "not a list", "x" ],
      [ "too many steps", Array.new(201) { |index| { "seq" => index + 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "file_read", "path" => "a.rb" } } } ],
      [ "a step that is not an object", [ "x" ] ],
      [ "a missing number", [ { "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "file_read", "path" => "a.rb" } } ] ],
      [ "a number that is not positive", [ { "seq" => 0, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "file_read", "path" => "a.rb" } } ] ],
      [ "a time that is not a time", [ { "seq" => 1, "at" => "yesterday", "event" => { "kind" => "file_read", "path" => "a.rb" } } ] ],
      [ "an unknown kind", [ { "seq" => 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "shell", "path" => "a.rb" } } ] ],
      [ "a missing path", [ { "seq" => 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "file_read" } } ] ],
      [ "an absolute path", [ { "seq" => 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "file_read", "path" => "/etc/passwd" } } ] ],
      [ "a negative count", [ { "seq" => 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "file_change", "path" => "a.rb", "created" => false, "added" => -1, "removed" => 0, "hunks" => nil } } ] ],
      [ "a line that is not text", [ { "seq" => 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "file_change", "path" => "a.rb", "created" => false, "added" => 1, "removed" => 0, "hunks" => [ { "oldStart" => 1, "oldLines" => 0, "newStart" => 1, "newLines" => 1, "lines" => [ 1 ] } ] } } ] ],
      [ "too many lines of code", [ { "seq" => 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "file_change", "path" => "a.rb", "created" => false, "added" => 401, "removed" => 0, "hunks" => [ { "oldStart" => 1, "oldLines" => 0, "newStart" => 1, "newLines" => 401, "lines" => Array.new(401, "+x") } ] } } ] ],
      [ "a command too long", [ { "seq" => 1, "at" => "2026-11-02T15:00:00Z", "event" => { "kind" => "command", "command" => "x" * 1001 } } ] ]
    ].each do |label, events|
      it "refuses #{label}" do
        result = record(events)

        expect(result).to be_err
        expect(result.error.code).to eq("R422-LIVE-001")
        expect(attempt.live_events).to be_empty
      end
    end
  end
end
