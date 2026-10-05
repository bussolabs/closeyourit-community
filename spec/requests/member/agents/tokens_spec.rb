# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Agents::Tokens", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  it "index risponde 200" do
    sign_in(owner)
    get member_agents_tokens_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="agent-token-form"')
  end

  it "sotto il titolo i conteggi dei token, non una spiegazione" do
    sign_in(owner)
    Agents::Tokens::Issue.call(organization: org, name: "attivo")
    Agents::Tokens::Revoke.call(token: Agents::Tokens::Issue.call(organization: org, name: "vecchio").value[:token])

    get member_agents_tokens_path

    counts = Nokogiri::HTML(response.body).at_css('[data-test="agent-tokens-counts"]').text.squish
    expect(counts).to include("2 #{I18n.t('member.agents.tokens.stat_total').downcase}")
    expect(counts).to include("1 #{I18n.t('member.agents.tokens.stat_active').downcase}")
    expect(counts).to include("1 #{I18n.t('member.agents.tokens.stat_revoked').downcase}")
    expect(response.body).not_to include("org-scoped")
  end

  it "un membro senza agents.manage → redirect (forbidden)" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    sign_in(member)
    get member_agents_tokens_path
    expect(response).to redirect_to(root_path)
  end

  it "create emette il token e mostra il segreto una sola volta (reveal-once)" do
    sign_in(owner)
    expect { post member_agents_tokens_path, params: { confirm: "1", name: "automator" } }
      .to change(Agents::Token, :count).by(1)
    expect(response).to have_http_status(:created)
    token = Agents::Token.order(:created_at).last
    expect(response.body).to include(token.token_prefix)
    expect(response.body).to include('data-test="agent-token-secret"')
  end

  it "create con nome vuoto → 422 e nessun token" do
    sign_in(owner)
    expect { post member_agents_tokens_path, params: { name: "" } }.not_to change(Agents::Token, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "destroy revoca il token" do
    sign_in(owner)
    token = Agents::Tokens::Issue.call(organization: org, name: "automator").value[:token]
    delete member_agents_token_path(token), params: { confirm: "1" }
    expect(response).to redirect_to(member_agents_tokens_path)
    expect(token.reload).to be_revoked
  end
  # CYRA-924 — delete asks in a dialog that names the thing, never in the browser box (F16, C77).
  describe "delete confirmation (dialog)" do
    it "opens a dialog that sends the revoke" do
      sign_in(owner)
      token = Agents::Tokens::Issue.call(organization: org, name: "automator").value[:token]

      get member_agents_tokens_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='agent-token-revoke-dialog-#{token.id}']")
      expect(dialog.text).to include(I18n.t("member.agents.tokens.revoke_dialog.title", name: "automator"))
      expect(dialog.at_css("form")["action"]).to eq(member_agents_token_path(token))
      expect(dialog.at_css("input[name='confirm']")["value"]).to eq("1")
      expect(html.at_css("[data-test='agent-token-revoke-#{token.id}']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
