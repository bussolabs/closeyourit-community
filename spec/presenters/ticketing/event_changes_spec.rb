# frozen_string_literal: true

require "rails_helper"

# CYRA-1309 — every shape an `updated` event stores becomes the same before/after pair of texts.
RSpec.describe Ticketing::EventChanges do
  def changes_for(data, action: "updated")
    described_class.call(build(:ticket_event, action: action, data: data))
  end

  it "reads a column change stored as a [before, after] pair" do
    changes = changes_for({ "description" => [ "Old text", "New text" ] })

    expect(changes).to eq([ described_class::Change.new("description", "Old text", "New text") ])
  end

  it "reads a lookup change stored as from/to labels" do
    changes = changes_for({ "priority" => { "from" => "Low", "to" => "High" } })

    expect(changes).to eq([ described_class::Change.new("priority", "Low", "High") ])
  end

  it "turns platforms removed and added into the before and after lines" do
    changes = changes_for({ "platforms" => { "added" => %w[Android Web], "removed" => [ "iOS" ] } })

    expect(changes).to eq([ described_class::Change.new("platforms", "iOS", "Android\nWeb") ])
  end

  it "keeps an empty side as an empty text" do
    changes = changes_for({ "weight" => [ nil, 3 ] })

    expect(changes).to eq([ described_class::Change.new("weight", "", "3") ])
  end

  it "orders fields as the history sentence does" do
    changes = changes_for({ "technical_analysis" => [ "a", "b" ], "title" => [ "c", "d" ] })

    expect(changes.map(&:field)).to eq(%w[title technical_analysis])
  end

  it "has nothing to show for events that are not edits" do
    expect(changes_for({ "status" => { "from" => "Open", "to" => "Done" } }, action: "status_changed")).to be_empty
  end
end
