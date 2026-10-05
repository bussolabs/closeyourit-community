# frozen_string_literal: true

require "rails_helper"

# CYRA-914 phase 2 — the organization AI page. Gate ai.manage; the organization is always the current
# one (no id in the path), keys never come back to the page.
RSpec.describe "Member::OrganizationAi", type: :request do
  let(:org) { create(:organization) }
  let(:other_org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:manager) { create(:account) }
  let(:member) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: manager, organization: org, role: :member)
    create(:membership, account: member, organization: org, role: :member)
    create(:account_permission, account: manager, organization: org, permission_key: "ai.manage", effect: :allow)
  end

  after { Ai::Configuration.reset! }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def own_params(**extra)
    { mode: "own", base_url: "https://llm.acme.test/v1", api_key: "sk-acme-secret", chat_model: "acme-chat" }.merge(extra)
  end

  describe "GET show" do
    it "is closed to members without ai.manage" do
      sign_in(member)
      get member_organization_ai_path
      expect(response).to redirect_to(root_path)
    end

    it "opens for whoever has ai.manage and says where each value comes from" do
      sign_in(manager)
      get member_organization_ai_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="org-ai-source-chat_model-environment"')
    end

    it "shows the platform token cap set in Valhalla" do
      Settings::Global.instance.update!(ai_org_monthly_token_cap: 200_000)
      sign_in(owner)
      get member_organization_ai_path
      expect(response.body).to include('data-test="org-ai-source-monthly_token_cap-valhalla"')
    end

    it "never shows a stored key" do
      org.create_ai_setting!(**own_params)
      sign_in(owner)
      get member_organization_ai_path
      expect(response.body).not_to include("sk-acme-secret")
      expect(response.body).to include('data-test="org-ai-source-api_key-organization"')
    end

    it "reads the same in Italian and English" do
      owner.update!(locale: "it")
      sign_in(owner)
      get member_organization_ai_path
      expect(response.body).not_to include("translation missing", "Translation missing")
    end
  end

  describe "PATCH update" do
    it "saves a variation for the current organization" do
      sign_in(manager)
      patch member_organization_ai_path, params: { confirm: "1", mode: "variation", chat_model: "big-chat" }
      expect(response).to redirect_to(member_organization_ai_path)
      expect(org.reload.ai_setting).to have_attributes(mode: "variation", chat_model: "big-chat")
    end

    it "keeps the stored key when the key field is left empty" do
      org.create_ai_setting!(**own_params)
      sign_in(owner)
      patch member_organization_ai_path, params: own_params(confirm: "1", api_key: "", chat_model: "acme-chat-2")
      expect(org.reload.ai_setting).to have_attributes(api_key: "sk-acme-secret", chat_model: "acme-chat-2")
    end

    it "explains what is missing for an own provider" do
      sign_in(owner)
      patch member_organization_ai_path, params: { confirm: "1", mode: "own" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload.ai_setting).to be_nil
    end

    it "asks for confirmation before saving" do
      sign_in(owner)
      patch member_organization_ai_path, params: { mode: "variation", chat_model: "big-chat" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload.ai_setting).to be_nil
    end

    it "is closed to members without ai.manage" do
      sign_in(member)
      patch member_organization_ai_path, params: { mode: "variation", chat_model: "big-chat" }
      expect(response).to redirect_to(root_path)
      expect(org.reload.ai_setting).to be_nil
    end

    it "never writes another organization's settings, whatever the request says" do
      create(:membership, account: owner, organization: other_org, role: :member)
      sign_in(owner)
      patch member_organization_ai_path,
            params: { confirm: "1", mode: "variation", chat_model: "big-chat", organization_id: other_org.id }
      expect(other_org.reload.ai_setting).to be_nil
      expect(org.reload.ai_setting.chat_model).to eq("big-chat")
    end
  end

  describe "a new search model" do
    # Recalculating makes sense only when search is on: it needs an embedding address.
    around do |example|
      saved = ENV.fetch("EMBED_BASE_URL", nil)
      ENV["EMBED_BASE_URL"] = "https://embed.test/v1"
      example.run
    ensure
      saved ? ENV["EMBED_BASE_URL"] = saved : ENV.delete("EMBED_BASE_URL")
    end

    it "asks to confirm the recalculation before saving" do
      sign_in(owner)
      patch member_organization_ai_path, params: { confirm: "1", mode: "variation", embedding_model: "embed-acme" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-test="org-ai-confirm-reindex"')
      expect(org.reload.ai_setting).to be_nil
    end

    it "recalculates only this organization once confirmed" do
      sign_in(owner)
      expect do
        patch member_organization_ai_path,
              params: { confirm: "1", confirm_reindex: "1", mode: "variation", embedding_model: "embed-acme" }
      end.to have_enqueued_job(Embeddings::ReembedOrganizationJob).with(organization_id: org.id)
      expect(org.reload.ai_setting.embedding_model).to eq("embed-acme")
    end

    it "keeps a key typed before the confirmation" do
      sign_in(owner)
      patch member_organization_ai_path, params: own_params(confirm: "1", embedding_model: "acme-embed")
      pending_keys = Capybara.string(response.body).find('input[name="pending_keys"]', visible: :all).value
      expect(response.body).not_to include("sk-acme-secret")

      patch member_organization_ai_path,
            params: own_params(confirm: "1", confirm_reindex: "1", api_key: "", embedding_model: "acme-embed",
                               pending_keys:)
      expect(org.reload.ai_setting.api_key).to eq("sk-acme-secret")
    end

    it "does not ask when the search model stays the same" do
      sign_in(owner)
      expect do
        patch member_organization_ai_path, params: { confirm: "1", mode: "variation", chat_model: "big-chat" }
      end.not_to have_enqueued_job(Embeddings::ReembedOrganizationJob)
    end
  end

  describe "POST test" do
    it "tries the typed provider without saving it" do
      sign_in(owner)
      allow(Ai::TestConnection).to receive(:call).and_return(Result.ok([]))
      post test_member_organization_ai_path, params: own_params
      expect(Ai::TestConnection).to have_received(:call) do |config:|
        expect(config.chat_base_url).to eq("https://llm.acme.test/v1")
      end
      expect(org.reload.ai_setting).to be_nil
    end

    it "never sends the stored key to a new address typed without it" do
      org.create_ai_setting!(**own_params)
      sign_in(owner)
      allow(Ai::TestConnection).to receive(:call).and_return(Result.ok([]))

      post test_member_organization_ai_path, params: own_params(base_url: "https://collector.example/v1", api_key: "")

      expect(Ai::TestConnection).to have_received(:call) { |config:| expect(config.api_key).to be_blank }
    end

    it "is closed to members without ai.manage" do
      sign_in(member)
      allow(Ai::TestConnection).to receive(:call)

      post test_member_organization_ai_path, params: own_params

      expect(response).to redirect_to(root_path)
      expect(Ai::TestConnection).not_to have_received(:call)
    end
  end

  it "asks for the key again when the provider address changes" do
    org.create_ai_setting!(**own_params)
    sign_in(owner)

    patch member_organization_ai_path, params: own_params(confirm: "1", base_url: "https://collector.example/v1", api_key: "")

    expect(response).to have_http_status(:unprocessable_content)
    expect(org.reload.ai_setting.base_url).to eq("https://llm.acme.test/v1")
  end
end
