# frozen_string_literal: true

require "rails_helper"

RSpec.describe Replays::Read, type: :service do
  let(:project) { create(:project) }
  let(:session) { project.replay_sessions.create!(replay_session_id: "s1", started_at: Time.current) }

  def attach(seq, events)
    gz = ActiveSupport::Gzip.compress(JSON.generate(events))
    session.chunks.attach(io: StringIO.new(gz), filename: "s1-#{seq}.json.gz",
                          content_type: "application/gzip")
  end

  it "concatena gli eventi dei chunk in ordine di seq" do
    attach(1, [ { "type" => 4 } ])
    attach(0, [ { "type" => 2 }, { "type" => 3 } ])

    result = described_class.call(session:)
    expect(result).to be_ok
    expect(result.value).to eq([ { "type" => 2 }, { "type" => 3 }, { "type" => 4 } ])
  end

  it "salta un chunk corrotto senza far cadere gli altri" do
    attach(0, [ { "type" => 2 } ])
    session.chunks.attach(io: StringIO.new("non-gzip-bytes"), filename: "s1-1.json.gz",
                          content_type: "application/gzip")

    expect(described_class.call(session:).value).to eq([ { "type" => 2 } ])
  end

  it "ritorna [] per una sessione senza chunk" do
    expect(described_class.call(session:).value).to eq([])
  end
end
