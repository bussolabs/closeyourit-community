# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla::AiSettings", type: :request do
  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  let(:god) { create(:account, god: true) }
  let(:settings) { Settings::Global.instance }
  let(:custom) do
    { ai_provider: "custom", ai_base_url: "https://ai.test/v1", ai_api_key: "sk-test", ai_chat_model: "chat-m" }
  end

  describe "GET /valhalla/ai_settings" do
    it "shows the provider choice and the rerank explanation" do
      sign_in_as(god)
      get valhalla_ai_settings_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ai-provider")
      expect(response.body).to include("ai-rerank")
      expect(response.body).to include("Cohere, Jina, Voyage")
    end

    it "says what the server environment already provides, without ever showing the key" do
      sign_in_as(god)
      get valhalla_ai_settings_path

      summary = Nokogiri::HTML(response.body).at_css("[data-test='ai-environment-summary']")
      expect(summary).to be_present
      expect(summary.at_css("[data-test='ai-env-chat-on']")).to be_present
      expect(summary.text).to include(URI(ENV.fetch("AI_BASE_URL")).host)
      expect(summary.at_css("[data-test='ai-env-key-present']")).to be_present
      expect(response.body).not_to include(ENV.fetch("AI_API_KEY"))
    end

    it "also says whether the knowledge review is on, which needs CHAT_BASE_URL (CYRA-914 D12)" do
      sign_in_as(god)
      get valhalla_ai_settings_path
      off = Nokogiri::HTML(response.body).at_css("[data-test='ai-environment-summary']")

      saved = ENV.fetch("CHAT_BASE_URL", nil)
      ENV["CHAT_BASE_URL"] = "https://review.example.test/v1"
      Ai::Configuration.reset!
      get valhalla_ai_settings_path
      on = Nokogiri::HTML(response.body).at_css("[data-test='ai-environment-summary']")

      expect(off.at_css("[data-test='ai-env-review-off']")).to be_present
      expect(on.at_css("[data-test='ai-env-review-on']")).to be_present
      expect(on.text).to include("review.example.test")
    ensure
      saved ? ENV["CHAT_BASE_URL"] = saved : ENV.delete("CHAT_BASE_URL")
      Ai::Configuration.reset!
    end

    it "drops the environment summary once another provider is saved" do
      settings.update!(custom)
      sign_in_as(god)
      get valhalla_ai_settings_path

      expect(response.body).not_to include("ai-environment-summary")
    end

    it "sends a non-god account home" do
      sign_in_as(create(:account, god: false))
      get valhalla_ai_settings_path

      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH /valhalla/ai_settings" do
    before { sign_in_as(god) }

    it "saves a custom provider with the key encrypted" do
      patch valhalla_ai_settings_path, params: custom

      expect(response).to redirect_to(valhalla_ai_settings_path)
      expect(settings.reload.ai_provider).to eq("custom")
      expect(settings.ai_api_key).to eq("sk-test")
    end

    it "keeps the stored key when the key field is left empty" do
      settings.update!(custom)
      patch valhalla_ai_settings_path, params: custom.merge(ai_api_key: "", ai_chat_model: "other")

      expect(settings.reload.ai_api_key).to eq("sk-test")
      expect(settings.ai_chat_model).to eq("other")
    end

    it "saves the monthly token cap of each organization, and empty means none (CYRA-914)" do
      patch valhalla_ai_settings_path, params: { ai_provider: "environment", ai_org_monthly_token_cap: "200000" }
      expect(settings.reload.ai_org_monthly_token_cap).to eq(200_000)

      patch valhalla_ai_settings_path, params: { ai_provider: "environment", ai_org_monthly_token_cap: "" }
      expect(settings.reload.ai_org_monthly_token_cap).to be_nil
    end

    it "goes back to the environment" do
      settings.update!(custom)
      patch valhalla_ai_settings_path, params: { ai_provider: "environment" }

      expect(settings.reload.ai_provider).to be_nil
    end

    it "shows what to fix when a field is missing" do
      patch valhalla_ai_settings_path, params: custom.merge(ai_chat_model: "")

      expect(response).to have_http_status(:unprocessable_content)
      expect(settings.reload.ai_provider).to be_nil
    end

    context "when the search model changes" do
      let(:with_embeddings) { custom.merge(ai_embedding_model: "emb", ai_embedding_dimensions: 768) }

      it "asks to confirm before recalculating the search" do
        patch valhalla_ai_settings_path, params: with_embeddings

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("ai-confirm-reindex")
        expect(settings.reload.ai_provider).to be_nil
      end

      # What a browser sends back from the confirmation page: every named field with its rendered value.
      def resubmitted(body)
        Nokogiri::HTML(body).css("form#ai-settings-form input[name]").each_with_object({}) do |input, fields|
          next if %w[submit button].include?(input["type"]) || input["name"].start_with?("_")

          fields[input["name"]] = input["value"].to_s
        end
      end

      it "keeps the key typed before the confirmation, without ever showing it (CYRA-914 P9)" do
        settings.update!(custom.merge(ai_api_key: "sk-old"))

        patch valhalla_ai_settings_path, params: with_embeddings.merge(ai_api_key: "sk-new-typed")
        expect(response.body).not_to include("sk-new-typed")
        patch valhalla_ai_settings_path, params: resubmitted(response.body).merge("confirm_reindex" => "1")

        expect(settings.reload.ai_api_key).to eq("sk-new-typed")
        expect(settings.ai_embedding_model).to eq("emb")
      end

      it "saves and recalculates once confirmed" do
        expect do
          patch valhalla_ai_settings_path, params: with_embeddings.merge(confirm_reindex: "1")
        end.to have_enqueued_job(Embeddings::ResizeColumnsJob).with(dimensions: 768)

        expect(settings.reload.ai_embedding_model).to eq("emb")
      end
    end
  end

  describe "POST /valhalla/ai_settings/test" do
    before { sign_in_as(god) }

    it "tries the values on the form without saving them" do
      stub_request(:post, "https://ai.test/v1/chat/completions")
        .to_return(status: 200, body: { choices: [ { message: { content: "pong" } } ] }.to_json)

      post test_valhalla_ai_settings_path, params: custom

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ai-test-chat-ok")
      expect(settings.reload.ai_provider).to be_nil
    end
  end
end
