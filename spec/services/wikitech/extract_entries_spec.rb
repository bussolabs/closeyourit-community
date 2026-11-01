# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::ExtractEntries do
  let(:client) { instance_double(Ai::Llm::Client) }
  let(:note) { create(:wikitech_note, body: "Follow me! Godot is an open-source engine for 2D games.", links: [ "https://github.com/godotengine/godot" ]) }

  it "sends the note with its source and links and returns cleaned items" do
    allow(client).to receive(:generate_content).and_return(
      "items" => [
        { "name" => "  Godot ", "repo_url" => "https://github.com/GodotEngine/godot", "summary" => "Engine for 2D and 3D games.",
          "facts" => [ "Free", "Free", " " ], "categories" => [ "Game Dev", "game dev" ],
          "links" => [ "https://godotengine.org", "not a link" ], "quote" => "It is open source." },
        { "name" => " ", "summary" => "nameless" }
      ]
    )

    result = described_class.call(note: note, client: client)

    expect(client).to have_received(:generate_content) do |system:, contents:, **|
      expect(system).to include("Drop everything else")
      expect(system).to include("trust the project page")
      text = contents.first[:parts].first[:text]
      expect(text).to include("TikTok @github.signals", "https://github.com/godotengine/godot", "Godot is an open-source")
    end
    expect(result.value.size).to eq(1)
    expect(result.value.first).to have_attributes(name: "Godot", repo_url: "https://github.com/godotengine/godot",
                                                  facts: [ "Free" ], categories: [ "game dev" ],
                                                  links: [ "https://godotengine.org" ], quote: "It is open source.")
  end

  it "returns an empty list when the model finds nothing technical" do
    allow(client).to receive(:generate_content).and_return("items" => [])

    expect(described_class.call(note: note, client: client).value).to eq([])
  end

  it "turns a client error into an error result with the same code" do
    allow(client).to receive(:generate_content).and_raise(Ai::Llm::Client::Error.new("down", code: "R503-LLM-001", status: :service_unavailable))

    result = described_class.call(note: note, client: client)

    expect(result.error).to have_attributes(code: "R503-LLM-001", status: :service_unavailable)
  end

  it "reports a missing AI configuration as a clean error" do
    allow(client).to receive(:generate_content).and_raise(KeyError)

    expect(described_class.call(note: note, client: client).error.code).to eq("R502-LLM-002")
  end
end
