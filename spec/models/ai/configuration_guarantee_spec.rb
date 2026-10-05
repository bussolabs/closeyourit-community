# frozen_string_literal: true

require "rails_helper"

# CYRA-914 phase 2 — the safety net for closeyour.it. Organization settings and the integration
# values in Valhalla add sources in front of the ones we have today; with nothing saved in them, every
# field must come out exactly as it does now. Each case lists every field on purpose: a field added
# later without a decision about its fallback fails here.
RSpec.describe Ai::Configuration, "without organization settings" do
  after { described_class.reset! }

  def snapshot(**settings)
    Settings::Global.instance.update!(settings) if settings.any?
    described_class.reset!
    described_class.current.to_h.except(:sources)
  end

  it "reads every field from the environment when Valhalla has no provider" do
    expect(snapshot).to eq(
      provider: nil, api_key: ENV["AI_API_KEY"], chat_base_url: ENV["AI_BASE_URL"],
      review_base_url: ENV["CHAT_BASE_URL"], embed_base_url: ENV["EMBED_BASE_URL"],
      chat_model: Ai::Llm::Constants::MODEL, embedding_model: Ai::Constants::EMBEDDING_MODEL,
      embedding_dimensions: Ai::Constants::EMBEDDING_DIMENSIONS,
      embedding_version: Ai::Constants::EMBEDDING_VERSION,
      transcription_model: Ai::Llm::Constants::TRANSCRIPTION_MODEL,
      rerank_base_url: ENV["EMBED_BASE_URL"], rerank_api_key: ENV["AI_API_KEY"],
      rerank_model: Ai::Constants.rerank_model, monthly_token_cap: nil
    )
  end

  it "keeps the CloseYourIt AI provider exactly as it is today" do
    url = described_class::CLOSEYOURIT_BASE_URL

    expect(snapshot(ai_provider: "closeyourit", ai_api_key: "cyi_ai_guarantee")).to eq(
      provider: "closeyourit", api_key: "cyi_ai_guarantee", chat_base_url: url, review_base_url: url,
      embed_base_url: url, chat_model: Ai::Llm::Constants::MODEL,
      embedding_model: Ai::Constants::EMBEDDING_MODEL,
      embedding_dimensions: Ai::Constants::EMBEDDING_DIMENSIONS,
      embedding_version: Ai::Constants::EMBEDDING_VERSION,
      transcription_model: Ai::Llm::Constants::TRANSCRIPTION_MODEL,
      rerank_base_url: url, rerank_api_key: "cyi_ai_guarantee", rerank_model: Ai::Constants::RERANK_MODEL,
      monthly_token_cap: nil
    )
  end

  it "keeps a custom provider exactly as it is today" do
    settings = { ai_provider: "custom", ai_api_key: "sk-guarantee", ai_base_url: "https://llm.example.com/v1/",
                 ai_chat_model: "chat-m", ai_embedding_model: "embed-m", ai_embedding_dimensions: 768,
                 ai_transcription_model: "voice-m", ai_rerank_base_url: "https://rr.example.com/v1/",
                 ai_rerank_api_key: "rr-guarantee", ai_rerank_model: "rerank-m" }

    expect(snapshot(**settings)).to eq(
      provider: "custom", api_key: "sk-guarantee", chat_base_url: "https://llm.example.com/v1",
      review_base_url: "https://llm.example.com/v1", embed_base_url: "https://llm.example.com/v1",
      chat_model: "chat-m", embedding_model: "embed-m", embedding_dimensions: 768,
      embedding_version: "custom:embed-m:768", transcription_model: "voice-m",
      rerank_base_url: "https://rr.example.com/v1", rerank_api_key: "rr-guarantee", rerank_model: "rerank-m",
      monthly_token_cap: nil
    )
  end
end
