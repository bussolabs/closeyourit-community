# frozen_string_literal: true

require "rails_helper"

# CYRA-1138 — what the live page of an attempt shows, rebuilt from the stored steps.
RSpec.describe Agents::LiveEvents::Session do
  let(:organization) { create(:organization) }
  let(:host) { create(:agent_host, organization:) }
  let(:workflow) { create(:agent_workflow, organization:, triage_started_at: Time.current) }
  let(:attempt) { create(:agent_attempt, workflow:, organization:, host:, phase: "triage", status: :running) }
  let(:at) { Time.utc(2026, 11, 2, 15) }

  def step(seq, kind, payload)
    Agents::AttemptLiveEvent.create!(organization:, attempt:, seq:, kind:, payload:, recorded_at: at + seq.seconds,
                                     created_at: Time.current)
  end

  def change(path, added:, removed:, hunks: nil, created: false)
    { "path" => path, "created" => created, "added" => added, "removed" => removed, "hunks" => hunks }
  end

  let(:hunk) { { "old_start" => 3, "old_lines" => 1, "new_start" => 3, "new_lines" => 2, "lines" => [ "-a", "+b", "+c" ] } }

  it "lists the touched files with their totals and follows the last one changed" do
    step(1, "file_read", { "path" => "app/models/ticket.rb" })
    step(2, "file_change", change("app/models/ticket.rb", added: 2, removed: 1))
    step(3, "file_change", change("config/locales/it.yml", added: 1, removed: 0, created: true))
    step(4, "file_change", change("app/models/ticket.rb", added: 1, removed: 0))
    step(5, "file_read", { "path" => "README.md" })

    session = described_class.new(attempt:)

    expect(session.files.map { [ it.path, it.added, it.removed, it.changed?, it.created ] }).to eq(
      [ [ "README.md", 0, 0, false, false ], [ "app/models/ticket.rb", 3, 1, true, false ],
        [ "config/locales/it.yml", 1, 0, true, true ] ]
    )
    expect(session.followed_path).to eq("app/models/ticket.rb")
    expect(session.file("app/models/ticket.rb").changes.map(&:seq)).to eq([ 2, 4 ])
  end

  it "keeps the code of each change only when it arrived" do
    step(1, "file_change", change("a.rb", added: 2, removed: 1, hunks: [ hunk ]))
    step(2, "file_change", change("b.rb", added: 1, removed: 0))

    session = described_class.new(attempt:)

    expect(session.code?).to be(true)
    expect(session.file("a.rb").changes.first.hunks.first).to have_attributes(old_start: 3, new_start: 3, lines: [ "-a", "+b", "+c" ])
    expect(session.file("b.rb").changes.first.hunks).to be_nil
  end

  it "has no code when no change carried any" do
    step(1, "file_change", change("a.rb", added: 1, removed: 0))

    expect(described_class.new(attempt:).code?).to be(false)
  end

  it "has no code when the changes carry only where they happened (CYAU-299)" do
    step(1, "file_change", change("a.rb", added: 1, removed: 0, hunks: [ hunk.merge("lines" => []) ]))

    expect(described_class.new(attempt:).code?).to be(false)
  end

  it "tells the newest steps first, each with what it was about" do
    step(1, "file_read", { "path" => "a.rb" })
    step(2, "search", { "pattern" => "def call" })
    step(3, "command", { "command" => "bin/rspec spec/a_spec.rb" })
    step(4, "file_change", change("a.rb", added: 1, removed: 0))

    timeline = described_class.new(attempt:).timeline

    expect(timeline.map { [ it.kind, it.text ] }).to eq(
      [ [ "file_change", "a.rb" ], [ "command", "bin/rspec spec/a_spec.rb" ], [ "search", "def call" ], [ "file_read", "a.rb" ] ]
    )
    expect(timeline.first).to have_attributes(at: at + 4.seconds, added: 1, removed: 0)
  end

  it "says when the machine stopped recording at its size cap" do
    step(1, "truncated", {})

    expect(described_class.new(attempt:).truncated?).to be(true)
  end

  it "reads only the most recent steps of a very long session" do
    stub_const("#{described_class}::LIMIT", 2)
    step(1, "file_read", { "path" => "old.rb" })
    step(2, "file_read", { "path" => "a.rb" })
    step(3, "file_read", { "path" => "b.rb" })

    expect(described_class.new(attempt:).files.map(&:path)).to eq(%w[a.rb b.rb])
  end

  it "has nothing to follow before the first change" do
    session = described_class.new(attempt:)

    expect([ session.files, session.timeline, session.followed_path ]).to eq([ [], [], nil ])
  end
end
