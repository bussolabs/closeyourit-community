# frozen_string_literal: true

require "rails_helper"

# DESIGN.md A32: the person picks light, dark or the system setting; the member pages put `dark` on <html>.
RSpec.describe "Member theme preference", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def html_tag = Nokogiri::HTML(response.body).at_css("html")
  def theme_meta = Nokogiri::HTML(response.body).at_css("meta[name='color-theme']")&.[]("content")

  it "offers light, dark and system on the preferences page, light by default" do
    get member_preferences_path

    doc = Nokogiri::HTML(response.body)
    %w[light dark system].each { expect(doc.at_css("input[name='theme'][value='#{it}']")).to be_present }
    expect(doc.at_css("input[name='theme'][value='light']")["checked"]).to be_present
    expect(html_tag["class"].to_s).not_to include("dark")
    expect(theme_meta).to eq("light")
  end

  it "saves dark and renders the member pages dark" do
    patch member_preferences_path, params: { theme: "dark" }

    expect(account.reload.theme).to eq("dark")
    get member_preferences_path
    expect(html_tag["class"].to_s.split).to include("dark")
  end

  it "follows the system setting when system is chosen" do
    patch member_preferences_path, params: { theme: "system" }

    get member_preferences_path
    expect(html_tag["data-theme"]).to eq("system")
    expect(html_tag["class"].to_s.split).not_to include("dark")
    expect(response.body).to include("prefers-color-scheme: dark")
    expect(theme_meta).to eq("system")
  end

  # Turbo never swaps <html>: the meta is what re-applies the right theme after a Turbo visit.
  it "lets the login page follow the system setting" do
    delete logout_path
    get login_path

    expect(theme_meta).to eq("system")
    expect(html_tag["class"].to_s.split).not_to include("dark")
  end

  it "ignores a theme that does not exist" do
    account.update!(theme: "dark")
    patch member_preferences_path, params: { theme: "neon" }

    expect(account.reload.theme).to eq("dark")
  end

  it "renders the account pages dark too" do
    account.update!(theme: "dark")
    get account_two_factor_path

    expect(html_tag["class"].to_s.split).to include("dark")
    expect(Nokogiri::HTML(response.body).at_css("body")["class"]).to include("dark:bg-zinc-950")
  end
end
