# frozen_string_literal: true

require "rails_helper"

# CYRA-1085 — a public demo prints the visitor password on the website. Turning on 2FA with it, or
# closing the other sessions, would sign every other visitor out and lock the account until the
# nightly reset. The account named in DEMO_ACCOUNT_EMAIL refuses both.
RSpec.describe "Shared demo account", type: :request do
  let(:demo) { create(:account, email: "demo@example.com", password: "Secret123!") }
  let(:alert) { I18n.t("account.shared_demo.locked", locale: :en) }

  around do |example|
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    example.run
  ensure
    ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!", locale: "en" }
  end

  it "refuses the 2FA setup page" do
    sign_in(demo)
    get setup_account_two_factor_path

    expect(response).to redirect_to(account_two_factor_path)
    expect(demo.reload.otp_secret).to be_nil
  end

  it "refuses turning on 2FA, even with the right password" do
    sign_in(demo)
    post enable_account_two_factor_path, params: { password: "Secret123!", code: "000000" }

    expect(response).to redirect_to(account_two_factor_path)
    expect(demo.reload).not_to be_otp_enabled
  end

  it "keeps the other visitors signed in when one closes the other sessions" do
    other_visitor = create(:session, account: demo)
    sign_in(demo)
    delete others_account_sessions_path

    expect(response).to redirect_to(account_sessions_path)
    expect(Accounts::Session.exists?(other_visitor.id)).to be(true)
  end

  it "keeps another visitor signed in when one closes that session" do
    other_visitor = create(:session, account: demo)
    sign_in(demo)
    delete account_session_path(other_visitor)

    expect(Accounts::Session.exists?(other_visitor.id)).to be(true)
  end

  it "leaves every other account free to turn on 2FA" do
    someone = create(:account, email: "ada@example.com", password: "Secret123!")
    sign_in(someone)
    get setup_account_two_factor_path

    expect(response).to have_http_status(:ok)
  end

  it "matches the address case-insensitively" do
    demo.update!(email: "Demo@Example.com")

    expect(demo).to be_shared_demo
  end

  it "treats no account as the demo when the variable is unset" do
    ENV.delete("DEMO_ACCOUNT_EMAIL")

    expect(demo).not_to be_shared_demo
  end
end
