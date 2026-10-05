# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::TestConnection do
  let(:settings) do
    Settings::Global.new(ai_provider: "custom", ai_api_key: "sk-test", ai_base_url: "https://ai.test/v1",
                         ai_chat_model: "chat-m", ai_embedding_model: "emb-m", ai_embedding_dimensions: 3)
  end
  let(:config) { Ai::Configuration.build(settings) }

  def checks = described_class.call(config:).value.index_by(&:key)

  before do
    stub_request(:post, "https://ai.test/v1/chat/completions")
      .to_return(status: 200, body: { choices: [ { message: { content: "pong" } } ] }.to_json)
    stub_request(:post, "https://ai.test/v1/embeddings")
      .to_return(status: 200, body: { data: [ { index: 0, embedding: [ 0.1, 0.2, 0.3 ] } ] }.to_json)
  end

  it "reports which features work with the values on the form" do
    result = checks

    expect(result[:chat].status).to eq(:ok)
    expect(result[:embeddings].status).to eq(:ok)
    expect(result[:transcription].status).to eq(:off)
    expect(result[:rerank].status).to eq(:off)
  end

  it "does not send vLLM-only fields to a custom provider" do
    checks

    expect(a_request(:post, "https://ai.test/v1/chat/completions")
      .with { |request| !JSON.parse(request.body).key?("chat_template_kwargs") }).to have_been_made
  end

  it "says the real size when the model returns a different one" do
    stub_request(:post, "https://ai.test/v1/embeddings")
      .to_return(status: 200, body: { data: [ { index: 0, embedding: [ 0.1, 0.2 ] } ] }.to_json)

    expect(checks[:embeddings]).to have_attributes(status: :failed, detail: "size 2, expected 3")
  end

  it "reports a refused key without raising" do
    stub_request(:post, "https://ai.test/v1/chat/completions").to_return(status: 401, body: "{}")

    expect(checks[:chat]).to have_attributes(status: :failed, detail: "HTTP 401")
  end

  # CYRA-914 D10: the badge was green without any call, even with a model the provider does not have.
  context "with a dictation model" do
    let(:settings) do
      Settings::Global.new(ai_provider: "custom", ai_api_key: "sk-test", ai_base_url: "https://ai.test/v1",
                           ai_chat_model: "chat-m", ai_transcription_model: "whisper-x")
    end

    it "sends a short silent recording and is ok when the provider transcribes it" do
      stub_request(:post, "https://ai.test/v1/audio/transcriptions").to_return(status: 200, body: { text: "" }.to_json)

      expect(checks[:transcription].status).to eq(:ok)
      expect(a_request(:post, "https://ai.test/v1/audio/transcriptions")
        .with { |request| request.body.include?("whisper-x") && request.body.b.include?("RIFF".b) }).to have_been_made
    end

    it "fails when the provider refuses the model" do
      stub_request(:post, "https://ai.test/v1/audio/transcriptions").to_return(status: 404, body: "{}")

      expect(checks[:transcription]).to have_attributes(status: :failed, detail: "HTTP 404")
    end
  end
end
