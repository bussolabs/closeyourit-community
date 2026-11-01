# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::EmbeddingText do
  it "puts name, summary, facts, categories and the repository description in the text" do
    entry = build(:wikitech_entry, name: "Godot", summary: "Engine.", facts: [ "Free", "GDScript" ],
                                   categories: [ "game dev" ], repo_meta: { "description" => "Game engine" })

    expect(described_class.call(entry: entry)).to eq("Name: Godot\nSummary: Engine.\nFacts: Free; GDScript\n" \
                                                     "Categories: game dev\nRepository: Game engine")
  end

  it "changes the checksum when the text changes" do
    entry = create(:wikitech_entry)
    before = described_class.checksum(entry: entry)
    entry.facts += [ "New fact" ]

    expect(described_class.checksum(entry: entry)).not_to eq(before)
  end
end
