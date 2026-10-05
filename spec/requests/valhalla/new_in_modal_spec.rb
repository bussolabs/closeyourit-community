# frozen_string_literal: true

require "rails_helper"

# CYRA-933 — in Valhalla too every New opens in the modal: a request for the "modal" frame gets the
# form alone, everything else keeps the full page.
RSpec.describe "Valhalla New forms in the modal", type: :request do
  let(:god) { create(:account, god: true) }
  let(:modal) { { "Turbo-Frame" => "modal" } }

  before do
    enable_two_factor!(god)
    post login_path, params: { email: god.email, password: "Secret123!" }
    complete_two_factor(god)
  end

  def doc = Nokogiri::HTML(response.body)

  it "carries the modal the New links open in" do
    get valhalla_accounts_path

    dialog = doc.at_css("dialog[data-test='member-modal']")
    expect(dialog["data-controller"]).to eq("ui--remote-modal")
    expect(dialog["class"]).to include("dark:text-zinc-100")
  end

  {
    "account" => [ :new_valhalla_account_path, "valhalla-account-form" ],
    "organization" => [ :new_valhalla_organization_path, "valhalla-organization-form" ],
    "AI key" => [ :new_valhalla_ai_gateway_key_path, "ai-key-form" ]
  }.select { |_, (route, _)| Rails.application.routes.url_helpers.respond_to?(route) }.each do |name, (route, form)|
    it "answers the modal frame with the new #{name} form alone" do
      get public_send(route), headers: modal

      expect(doc.at_css("turbo-frame#modal [data-test='#{form}']")).to be_present
      expect(doc.at_css("aside")).to be_nil
      expect(doc.at_css("turbo-frame#modal nav[aria-label='Breadcrumb']")).to be_nil
    end
  end

  it "keeps the full page for a direct visit" do
    get new_valhalla_account_path

    expect(doc.at_css("turbo-frame#modal")).to be_nil
    expect(doc.at_css("aside [data-test='valhalla-nav-accounts']")).to be_present
  end

  it "keeps a failed save in the modal, with its message" do
    post valhalla_accounts_path, params: { name: "", email: "" }, headers: modal

    expect(response).to have_http_status(:unprocessable_content)
    expect(doc.at_css("turbo-frame#modal [data-test='valhalla-account-form']")).to be_present
    expect(doc.at_css("turbo-frame#modal [data-test='modal-flash-alert']")).to be_present
  end

  it "answers a successful save with a full page, so the browser leaves the modal" do
    post valhalla_organizations_path, params: { name: "Modal Org", owner_email: god.email }, headers: modal
    follow_redirect!(headers: modal)

    expect(doc.at_css("turbo-frame#modal")).to be_nil
  end
end
