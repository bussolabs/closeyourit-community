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

    expect(client).to have_received(:generate_content) do |system:, contents:, max_output_tokens:, **|
      expect(max_output_tokens).to eq(Wikitech::Constants::EXTRACT_MAX_OUTPUT_TOKENS)
      expect(system).to include("Drop everything else")
      expect(system).to include("trust the project page")
      expect(system).to include("only named")
      text = contents.first[:parts].first[:text]
      expect(text).to include("TikTok @github.signals", "https://github.com/godotengine/godot", "Godot is an open-source")
    end
    expect(result.value.size).to eq(1)
    expect(result.value.first).to have_attributes(name: "Godot", repo_url: "https://github.com/godotengine/godot",
                                                  facts: [ "Free" ], categories: [ "game dev" ],
                                                  links: [ "https://godotengine.org" ], quote: "It is open source.")
  end

  it "asks for an 80-character purpose and cuts a longer one at a word, never mid-word" do
    long = "Strumento open source che converte un singolo video generato da AI in una animazione 3D completa"
    allow(client).to receive(:generate_content).and_return("items" => [ { "name" => "Anymove", "summary" => long } ])

    summary = described_class.call(note: note, client: client).value.first.summary

    expect(client).to have_received(:generate_content).with(hash_including(system: include("at most 80 characters")))
    expect(summary.length).to be <= 80
    expect(summary).to end_with("…")
    expect(long).to start_with(summary.delete_suffix("…"))
    expect(long[summary.length - 1]).to eq(" ")
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
