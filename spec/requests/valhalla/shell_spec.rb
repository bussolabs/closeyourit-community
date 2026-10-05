# frozen_string_literal: true

require "rails_helper"

# Valhalla wears the member shell: detached sidebar panel, framed content with flush panels, the
# person's theme. The red "god" marks are what tells the two areas apart.
RSpec.describe "Valhalla shell", type: :request do
  let(:god) { create(:account, god: true) }

  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  def page = Nokogiri::HTML(response.body)

  it "follows the theme the person chose" do
    god.update!(theme: "dark")
    sign_in_as(god)

    get valhalla_root_path

    expect(page.at_css("html")["class"]).to include("dark")
    expect(page.at_css("body")["class"]).to include("dark:bg-zinc-950")
  end

  it "stays light for whoever did not choose" do
    sign_in_as(god)

    get valhalla_root_path

    expect(page.at_css("html")["class"].to_s).not_to include("dark")
  end

  it "frames the page like the member area" do
    sign_in_as(god)

    get valhalla_root_path

    sidebar = page.at_css("#valhalla-sidebar")
    expect(sidebar["class"]).to include("md:rounded-xl", "bg-white", "dark:bg-zinc-900")
    expect(page.at_css("main#main-content")["data-panels"]).to eq("flush")
    expect(page.at_css("[data-test='valhalla-nav-dashboard']")["aria-current"]).to eq("page")
    expect(page.at_css("[data-test='valhalla-god-mark']")).to be_present
  end

  it "keeps every dashboard number inside a titled panel" do
    sign_in_as(god)

    get valhalla_root_path

    dashboard = page.at_css("[data-test='valhalla-dashboard']")
    expect(page.css("[data-test='valhalla-dashboard'] > h2")).to be_empty
    expect(dashboard.at_css("[data-test='valhalla-dashboard-totals'] [data-test='stat-accounts']")).to be_present
    expect(dashboard.css("[data-test='valhalla-dashboard-access'] [role='tab']").size).to eq(2)
  end
end
