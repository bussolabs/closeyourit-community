# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Credenziale AI comune" do
  around do |example|
    keys = %w[AI_API_KEY AI_BASE_URL CHAT_BASE_URL EMBED_BASE_URL EMBED_RERANK_MODEL CHAT_API_KEY EMBED_API_KEY]
    original = keys.index_with { |key| ENV[key] }
    ENV["AI_API_KEY"] = "shared-test-key"
    ENV["AI_BASE_URL"] = ENV["CHAT_BASE_URL"] = ENV["EMBED_BASE_URL"] = "https://ai.test/v1"
    ENV["EMBED_RERANK_MODEL"] = "rerank"
    ENV["CHAT_API_KEY"] = ENV["EMBED_API_KEY"] = "unused-legacy-key"
    example.run
  ensure
    original.each { |key, value| ENV[key] = value }
  end

  it "autentica generazione, revisione, embedding e rerank con la stessa chiave" do
    auth = { "Authorization" => "Bearer shared-test-key" }
    stream = "data: #{ { choices: [ { delta: { content: 'ok' }, finish_reason: 'stop' } ] }.to_json }\n\ndata: [DONE]\n\n"
    chat = stub_request(:post, "https://ai.test/v1/chat/completions").with(headers: auth)
      .to_return(body: stream)
    embed = stub_request(:post, "https://ai.test/v1/embeddings").with(headers: auth)
      .to_return(body: { data: [ { index: 0, embedding: [ 0.5 ] } ] }.to_json)
    rerank = stub_request(:post, "https://ai.test/v1/rerank").with(headers: auth)
      .to_return(body: { results: [ { index: 0, relevance_score: 0.8 } ] }.to_json)

    expect(Ai::Llm::Client.new.generate_content(system: "s", contents: [])).to eq("ok")
    expect(Ai::Llm::Client.new(credentials: :knowledge_review).generate_content(system: "s", contents: [])).to eq("ok")
    expect(Ai::Embedding::Client.new.embed(input: "test")).to eq([ [ 0.5 ] ])
    expect(Ai::Embedding::Client.new.rerank(query: "test", documents: [ "test" ])).to eq([ { index: 0, score: 0.8 } ])
    expect(chat).to have_been_requested.twice
    expect(embed).to have_been_requested.once
    expect(rerank).to have_been_requested.once
  end

  it "non ripiega sulle vecchie chiavi quando AI_API_KEY manca" do
    ENV.delete("AI_API_KEY")
    expect { Ai::Llm::Client.new }.to raise_error(KeyError, /AI_API_KEY/)
    expect { Ai::Llm::Client.new(credentials: :knowledge_review) }.to raise_error(KeyError, /AI_API_KEY/)
    expect { Ai::Embedding::Client.new }.to raise_error(KeyError, /AI_API_KEY/)
  end
end
