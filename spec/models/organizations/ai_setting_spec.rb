# frozen_string_literal: true

require "rails_helper"

RSpec.describe Organizations::AiSetting do
  let(:organization) { create(:organization) }

  def setting(**attributes) = described_class.new(organization:, **attributes)

  it "follows the platform by default" do
    expect(setting).to be_valid
    expect(setting.mode).to eq("platform")
  end

  it "rejects an unknown mode" do
    expect(setting(mode: "everything")).not_to be_valid
  end

  it "keeps one row per organization" do
    setting.save!

    expect { setting.save! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  describe "own provider" do
    it "needs an address, a key and a chat model" do
      record = setting(mode: "own")

      expect(record).not_to be_valid
      expect(record.errors.attribute_names).to include(:base_url, :api_key, :chat_model)
    end

    it "accepts an OpenAI-compatible address" do
      record = setting(mode: "own", base_url: "https://llm.example.com/v1", api_key: "sk-own", chat_model: "m")

      expect(record).to be_valid
    end

    it "refuses an address that is not http or https" do
      record = setting(mode: "own", base_url: "ftp://llm.example.com", api_key: "sk-own", chat_model: "m")

      expect(record).not_to be_valid
      expect(record.errors.attribute_names).to include(:base_url)
    end

    it "refuses an address inside the internal network (SSRF)" do
      [ "http://10.20.30.40/v1", "http://169.254.169.254", "http://127.0.0.1:3000", "http://localhost/v1",
        "http://ollama.internal/v1", "http://[::1]/v1" ].each do |url|
        record = setting(mode: "own", base_url: url, api_key: "sk-own", chat_model: "m", rerank_base_url: url)

        expect(record).not_to be_valid, url
        expect(record.errors.attribute_names).to include(:base_url, :rerank_base_url)
      end
    end
  end

  describe "variation" do
    it "cannot bring its own address or key: those belong to the platform" do
      record = setting(mode: "variation", base_url: "https://llm.example.com/v1", api_key: "sk-own")

      expect(record).not_to be_valid
      expect(record.errors.attribute_names).to include(:base_url, :api_key)
    end
  end

  it "accepts only a positive monthly token cap" do
    expect(setting(monthly_token_cap: 0)).not_to be_valid
    expect(setting(monthly_token_cap: 50_000)).to be_valid
    expect(setting(monthly_token_cap: nil)).to be_valid
  end

  describe "keys" do
    let(:record) do
      setting(mode: "own", base_url: "https://llm.example.com/v1", api_key: "sk-secret-own", chat_model: "m",
              rerank_api_key: "rr-secret-own").tap(&:save!)
    end

    it "stores them encrypted" do
      raw = described_class.connection.select_one(
        "SELECT api_key, rerank_api_key FROM organization_ai_settings WHERE id = #{described_class.connection.quote(record.id)}"
      )

      expect(raw.values.join).not_to include("sk-secret-own", "rr-secret-own")
    end

    it "never prints them in JSON or inspect" do
      expect(record.to_json).not_to include("sk-secret-own", "rr-secret-own")
      expect(record.inspect).not_to include("sk-secret-own", "rr-secret-own")
    end
  end
end
