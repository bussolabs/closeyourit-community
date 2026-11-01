# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::Entry do
  it "derives the merge key from the name" do
    entry = create(:wikitech_entry, name: "  Godot   Engine ")

    expect(entry.name).to eq("Godot Engine")
    expect(entry.name_key).to eq("godotengine")
  end

  it "reads the repository data" do
    entry = build(:wikitech_entry, repo_meta: { "stars" => 100, "license" => "MIT", "language" => "C++" })

    expect([ entry.stars, entry.license, entry.language ]).to eq([ 100, "MIT", "C++" ])
  end

  it "filters by category and searches name, summary and facts" do
    organization = create(:organization)
    engine = create(:wikitech_entry, organization: organization, name: "Godot", categories: [ "game dev" ])
    create(:wikitech_entry, organization: organization, name: "Plane", categories: [ "ticketing" ],
                            summary: "Project tracking", facts: [ "Alternative to Jira" ])

    expect(organization.wikitech_entries.in_category("Game Dev")).to contain_exactly(engine)
    expect(organization.wikitech_entries.text_search("jira").map(&:name)).to eq([ "Plane" ])
  end

  it "counts its sources" do
    source = create(:wikitech_source)

    expect(source.entry.reload.sources_count).to eq(1)
  end
end
