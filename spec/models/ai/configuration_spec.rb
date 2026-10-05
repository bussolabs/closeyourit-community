# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Configuration do
  after { described_class.reset! }

  def configure(**attributes)
    Settings::Global.instance.update!(attributes)
    described_class.reset!
    described_class.current
  end

  describe "without a provider chosen in Valhalla" do
    it "reads the environment, so existing installs keep working" do
      config = described_class.current

      expect(config.provider).to be_nil
      expect(config.chat_base_url).to eq(ENV.fetch("AI_BASE_URL"))
      expect(config.api_key).to eq(ENV.fetch("AI_API_KEY"))
      expect(config.chat_model).to eq(Ai::Llm::Constants::MODEL)
      expect(config.embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION)
      expect(config).to be_chat_configured
    end

    it "is not configured when the environment is empty" do
      saved = ENV.to_h.slice("AI_BASE_URL", "AI_API_KEY")
      ENV.delete("AI_BASE_URL")
      ENV.delete("AI_API_KEY")
      described_class.reset!

      expect(described_class.current).not_to be_chat_configured
    ensure
      saved.each { |name, value| ENV[name] = value }
    end
  end

  describe "with a CloseYourIt key" do
    it "sends everything to CloseYourIt AI with our models, rerank included" do
      config = configure(ai_provider: "closeyourit", ai_api_key: "cyi_ai_test")

      expect(config.chat_base_url).to eq(described_class::CLOSEYOURIT_BASE_URL)
      expect(config.embed_base_url).to eq(described_class::CLOSEYOURIT_BASE_URL)
      expect(config.api_key).to eq("cyi_ai_test")
      expect(config.embedding_dimensions).to eq(1024)
      expect(config).to be_rerank_configured
      expect(config).to be_transcription_configured
    end
  end

  describe "with a custom provider" do
    let(:base) do
      { ai_provider: "custom", ai_api_key: "sk-test", ai_base_url: "https://api.openai.com/v1/",
        ai_chat_model: "gpt-4o-mini" }
    end

    it "uses the admin's address and models" do
      config = configure(**base, ai_embedding_model: "text-embedding-3-small", ai_embedding_dimensions: 1536)

      expect(config.chat_base_url).to eq("https://api.openai.com/v1")
      expect(config.chat_model).to eq("gpt-4o-mini")
      expect(config.embedding_dimensions).to eq(1536)
      expect(config).to be_embeddings_configured
    end

    it "changes the embedding version when the model or the size changes, so everything is re-embedded" do
      first = configure(**base, ai_embedding_model: "a", ai_embedding_dimensions: 768).embedding_version
      second = configure(**base, ai_embedding_model: "a", ai_embedding_dimensions: 1024).embedding_version

      expect(first).not_to eq(second)
      expect(first).not_to eq(Ai::Constants::EMBEDDING_VERSION)
    end

    it "leaves search, voice and rerank off when their models are not set" do
      config = configure(**base)

      expect(config).to be_chat_configured
      expect(config).not_to be_embeddings_configured
      expect(config).not_to be_transcription_configured
      expect(config).not_to be_rerank_configured
    end

    it "turns rerank on only with address, key and model" do
      config = configure(**base, ai_rerank_base_url: "https://api.cohere.com/v2", ai_rerank_api_key: "co",
                                 ai_rerank_model: "rerank-v3.5")

      expect(config).to be_rerank_configured
      expect(config.rerank_base_url).to eq("https://api.cohere.com/v2")
    end
  end

  describe "settings validation" do
    let(:settings) { Settings::Global.instance }

    it "refuses an embedding size the search index cannot hold" do
      settings.assign_attributes(ai_provider: "custom", ai_api_key: "k", ai_base_url: "https://x.test/v1",
                                 ai_chat_model: "m", ai_embedding_model: "e", ai_embedding_dimensions: 3072)

      expect(settings).not_to be_valid
      expect(settings.errors[:ai_embedding_dimensions]).to be_present
    end

    it "requires a key for any provider" do
      settings.assign_attributes(ai_provider: "closeyourit", ai_api_key: "")

      expect(settings).not_to be_valid
    end

    it "stores the keys encrypted" do
      configure(ai_provider: "closeyourit", ai_api_key: "cyi_ai_secret")

      raw = Settings::Global.connection.select_value("SELECT ai_api_key FROM settings_global LIMIT 1")
      expect(raw).not_to include("cyi_ai_secret")
    end
  end

  # CYRA-914 D13: inspect was filtered, but to_json of the settings and both forms of the snapshot printed the
  # keys; one render json, log line or error report away from a leak.
  describe "keys never leave in clear" do
    let(:secrets) { %w[sk-never-printed co-never-printed] }

    before do
      Settings::Global.instance.update!(ai_provider: "custom", ai_api_key: secrets.first, ai_base_url: "https://x.test/v1",
                                        ai_chat_model: "m", ai_rerank_base_url: "https://r.test/v1",
                                        ai_rerank_api_key: secrets.last, ai_rerank_model: "r")
      described_class.reset!
    end

    it "not from the settings serialized to JSON" do
      json = Settings::Global.instance.to_json

      secrets.each { |secret| expect(json).not_to include(secret) }
    end

    it "not from the snapshot, inspected or serialized" do
      snapshot = described_class.current

      secrets.each do |secret|
        expect(snapshot.inspect).not_to include(secret)
        expect(snapshot.to_json).not_to include(secret)
      end
      expect(snapshot.api_key).to eq(secrets.first)
    end
  end
end
