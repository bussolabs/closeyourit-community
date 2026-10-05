# frozen_string_literal: true

require "rails_helper"

# CYRA-914 phase 2 — precedence organization -> Valhalla -> environment, with the source of each field.
RSpec.describe Ai::Configuration, "per organization" do
  let(:organization) { create(:organization) }
  let(:other) { create(:organization) }

  after do
    described_class.reset!
    Current.organization = nil
  end

  def config_for(org)
    described_class.reset!
    Current.organization = org
    described_class.current
  end

  def own(**attributes)
    { mode: "own", base_url: "https://llm.acme.test/v1/", api_key: "sk-acme", chat_model: "acme-chat" }.merge(attributes)
  end

  it "gives an organization without settings the platform configuration" do
    expect(config_for(organization).to_h.except(:sources)).to eq(config_for(nil).to_h.except(:sources))
  end

  it "says every platform field comes from the environment when Valhalla has no provider" do
    expect(config_for(organization).sources.values.uniq).to eq([ :environment ])
  end

  it "says the fields come from Valhalla when Valhalla has a provider" do
    Settings::Global.instance.update!(ai_provider: "closeyourit", ai_api_key: "cyi_ai_platform")

    sources = config_for(organization).sources

    expect(sources[:api_key]).to eq(:valhalla)
    expect(sources[:chat_base_url]).to eq(:valhalla)
  end

  describe "variation" do
    before do
      organization.create_ai_setting!(mode: "variation", chat_model: "big-chat", transcription_model: "voice-x")
    end

    it "changes only the models it sets and keeps the platform address and key" do
      config = config_for(organization)

      expect(config.chat_model).to eq("big-chat")
      expect(config.transcription_model).to eq("voice-x")
      expect(config.api_key).to eq(ENV["AI_API_KEY"])
      expect(config.sources).to include(chat_model: :organization, transcription_model: :organization,
                                        api_key: :environment)
    end

    it "does not touch the other organizations" do
      expect(config_for(other).chat_model).to eq(Ai::Llm::Constants::MODEL)
    end
  end

  describe "embeddings" do
    it "keeps the platform size and gives the organization its own version when it changes model" do
      organization.create_ai_setting!(mode: "variation", embedding_model: "embed-acme")

      config = config_for(organization)

      expect(config.embedding_model).to eq("embed-acme")
      expect(config.embedding_dimensions).to eq(Ai::Constants::EMBEDDING_DIMENSIONS)
      expect(config.sources[:embedding_dimensions]).to eq(:environment)
      expect(config.embedding_version).not_to eq(config_for(other).embedding_version)
    end

    it "keeps the platform version when the organization keeps the platform model" do
      organization.create_ai_setting!(mode: "variation", chat_model: "big-chat")

      expect(config_for(organization).embedding_version).to eq(Ai::Constants::EMBEDDING_VERSION)
    end
  end

  describe "own provider" do
    it "sends everything to the organization's provider" do
      organization.create_ai_setting!(**own(embedding_model: "acme-embed", rerank_base_url: "https://rr.acme.test/v1",
                                            rerank_api_key: "rr-acme", rerank_model: "acme-rerank"))

      config = config_for(organization)

      expect(config).to have_attributes(provider: "organization", api_key: "sk-acme",
                                        chat_base_url: "https://llm.acme.test/v1",
                                        review_base_url: "https://llm.acme.test/v1",
                                        embed_base_url: "https://llm.acme.test/v1", chat_model: "acme-chat",
                                        embedding_model: "acme-embed", rerank_model: "acme-rerank")
      expect(config.sources[:api_key]).to eq(:organization)
    end

    it "marks only the addresses the organization typed as untrusted" do
      organization.create_ai_setting!(**own(rerank_base_url: "https://rr.acme.test/v1"))

      config = config_for(organization)

      expect(config.untrusted_url?("https://llm.acme.test/v1/")).to be(true)
      expect(config.untrusted_url?("https://rr.acme.test/v1")).to be(true)
      expect(config_for(other).untrusted_url?(config_for(other).chat_base_url)).to be(false)
    end

    it "never prints the keys, not even through pp" do
      organization.create_ai_setting!(**own)

      expect(config_for(organization).pretty_inspect).not_to include("sk-acme")
    end

    it "leaves a feature off instead of mixing in the platform provider" do
      organization.create_ai_setting!(**own)

      config = config_for(organization)

      expect(config).to be_chat_configured
      expect(config).not_to be_embeddings_configured
      expect(config).not_to be_transcription_configured
      expect(config).not_to be_rerank_configured
    end

    it "gives the organization its own embedding version even with the platform model name" do
      organization.create_ai_setting!(**own(embedding_model: Ai::Constants::EMBEDDING_MODEL))

      expect(config_for(organization).embedding_version).not_to eq(Ai::Constants::EMBEDDING_VERSION)
    end
  end

  it "remembers each organization separately within the same request" do
    organization.create_ai_setting!(mode: "variation", chat_model: "big-chat")

    Current.organization = organization
    first = described_class.current.chat_model
    Current.organization = other
    second = described_class.current.chat_model

    expect([ first, second ]).to eq([ "big-chat", Ai::Llm::Constants::MODEL ])
  end
end
