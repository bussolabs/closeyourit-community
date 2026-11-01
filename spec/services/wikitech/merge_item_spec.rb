# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::MergeItem do
  let(:organization) { create(:organization) }
  let(:note) { create(:wikitech_note, organization: organization) }

  def item(**overrides)
    Wikitech::ExtractEntries::Item.new(**{ name: "Godot", repo_url: "https://github.com/godotengine/godot",
                                           summary: "Engine for games.", facts: [ "Free" ], categories: [ "game dev" ],
                                           links: [ "https://godotengine.org", "https://github.com/godotengine/godot" ],
                                           quote: "Open source." }.merge(overrides))
  end

  it "creates a card with a source for a new project" do
    entry = described_class.call(note: note, item: item).value

    expect(entry).to have_attributes(name: "Godot", repo_url: "https://github.com/godotengine/godot",
                                     summary: "Engine for games.", facts: [ "Free" ], links: [ "https://godotengine.org" ])
    expect(entry.sources.map { |s| [ s.note, s.quote ] }).to eq([ [ note, "Open source." ] ])
  end

  it "enriches the card of the same repository instead of duplicating it" do
    first = described_class.call(note: note, item: item).value
    other_note = create(:wikitech_note, organization: organization)

    second = described_class.call(note: other_note, item: item(name: "Godot Engine", summary: "Other words.",
                                                                facts: [ "free", "Uses GDScript" ], categories: [ "Open Source" ])).value

    expect(second).to eq(first)
    expect(second.reload).to have_attributes(summary: "Engine for games.", facts: [ "Free", "Uses GDScript" ],
                                             categories: [ "game dev", "Open Source" ], sources_count: 2)
  end

  it "merges by name when there is no repository, and adds the repository later" do
    nameless = described_class.call(note: note, item: item(repo_url: nil)).value

    merged = described_class.call(note: create(:wikitech_note, organization: organization), item: item).value

    expect(merged).to eq(nameless)
    expect(merged.repo_url).to eq("https://github.com/godotengine/godot")
  end

  it "keeps apart two projects with the same name and different repositories" do
    described_class.call(note: note, item: item)

    other = described_class.call(note: note, item: item(repo_url: "https://github.com/someone/godot")).value

    expect(organization.wikitech_entries.count).to eq(2)
    expect(other.repo_url).to eq("https://github.com/someone/godot")
  end

  it "does not add the same note twice as a source" do
    described_class.call(note: note, item: item)
    entry = described_class.call(note: note, item: item).value

    expect(entry.reload.sources_count).to eq(1)
  end

  it "merges into the card another note created at the same moment" do
    existing = create(:wikitech_entry, organization: organization, name: "Godot", repo_url: "https://github.com/godotengine/godot")
    calls = 0
    # The first lookup misses the card the other note is writing; the retry finds it.
    allow_any_instance_of(described_class).to receive(:find_or_build).and_wrap_original do |original| # rubocop:disable RSpec/AnyInstance
      calls += 1
      calls == 1 ? organization.wikitech_entries.new(name: "Godot") : original.call
    end

    entry = described_class.call(note: note, item: item).value

    expect(entry).to eq(existing)
    expect(calls).to eq(2)
  end
end
