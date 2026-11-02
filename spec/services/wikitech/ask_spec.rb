# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::Ask do
  let(:organization) { create(:organization) }
  let(:scope) { organization.wikitech_entries }
  let(:chat_client) { instance_double(Ai::Llm::Client) }
  let(:vector) { Array.new(1024, 0.1) }
  let!(:engine) do
    create(:wikitech_entry, organization: organization, name: "Godot", repo_url: "https://github.com/godotengine/godot",
                            repo_meta: { "license" => "MIT", "language" => "C++" }).tap do |entry|
      entry.update_columns(embedding: vector, embedding_version: Ai::Configuration.current.embedding_version)
    end
  end

  before do
    allow(Embeddings::QueryVector).to receive(:call).and_return(Result.ok(vector))
    allow(Embeddings::Rerank).to receive(:call).and_return(Result.ok([ 0 ]))
  end

  def ask(question = "Is there something to make games?")
    described_class.call(scope: scope, question: question, chat_client: chat_client)
  end

  it "answers from the cards and keeps only citations of real candidates" do
    allow(chat_client).to receive(:generate_content).and_return("answer" => "- Godot fits.", "cited_ids" => [ engine.id, "made-up" ])

    result = ask

    expect(chat_client).to have_received(:generate_content) do |contents:, **|
      expect(contents.first[:parts].first[:text]).to include("name: Godot", "MIT", "Question: Is there something")
    end
    expect(result.value).to have_attributes(answer: "- Godot fits.", entries: [ engine ], insufficient: false)
  end

  it "says it found nothing without calling the model when no card is close enough" do
    engine.update_columns(embedding: nil)
    allow(chat_client).to receive(:generate_content)

    expect(ask.value).to have_attributes(insufficient: true, entries: [])
    expect(chat_client).not_to have_received(:generate_content)
  end

  it "refuses a blank question" do
    expect(ask(" ").error.code).to eq("R422-WIKITECH-004")
  end

  it "passes on an embedding failure and turns model errors into error results" do
    allow(Embeddings::QueryVector).to receive(:call).and_return(Result.err(AppError.new("down", code: "R502-AI-001")))
    expect(ask.error.code).to eq("R502-AI-001")

    allow(Embeddings::QueryVector).to receive(:call).and_return(Result.ok(vector))
    allow(chat_client).to receive(:generate_content).and_raise(Ai::Llm::Client::Error.new("x", code: "R503-LLM-001", status: :service_unavailable))
    expect(ask.error.code).to eq("R503-LLM-001")

    allow(chat_client).to receive(:generate_content).and_raise(KeyError)
    expect(ask.error.code).to eq("R502-LLM-002")
  end

  it "lets the model judge cards the reranker scores low and reads farther than the other searches" do
    # Distance 0.65: past the 0.6 of the shared searches, still a card about the question.
    engine.update_columns(embedding: [ 0.35, Math.sqrt(1 - (0.35**2)) ] + Array.new(1022, 0.0))
    allow(Embeddings::QueryVector).to receive(:call).and_return(Result.ok([ 1.0 ] + Array.new(1023, 0.0)))
    allow(chat_client).to receive(:generate_content).and_return("answer" => "ok", "cited_ids" => [ engine.id ])

    expect(ask.value.entries).to eq([ engine ])
    expect(Embeddings::Rerank).to have_received(:call).with(hash_including(min_score: nil))
  end

  it "keeps the cosine order when the reranker is down" do
    allow(Embeddings::Rerank).to receive(:call).and_return(Result.err(AppError.new("x", code: "R503-AI-002")))
    allow(chat_client).to receive(:generate_content).and_return("answer" => "ok", "cited_ids" => [ engine.id ])

    expect(ask.value.entries).to eq([ engine ])
  end
end
