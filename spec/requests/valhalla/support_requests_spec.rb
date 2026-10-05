# frozen_string_literal: true

require "rails_helper"

# CYRA-935 — support requests in Valhalla: the list, one request with its details, the handled mark.
RSpec.describe "Valhalla::SupportRequests", type: :request do
  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  let(:god) { create(:account, god: true) }
  let(:organization) { create(:organization, name: "Acme") }
  let(:sender) { create(:account, name: "Dana Member") }
  let!(:support_request) do
    Support::Request.create!(account: sender, organization:, body: "The board loses the column order.",
                             context: { "page" => "/member/tickets", "window" => "1440 × 900" })
  end

  it "is closed to an account that is not god" do
    sign_in_as(create(:account))

    get valhalla_support_requests_path

    expect(response).to redirect_to(root_path)
  end

  context "when signed in as god" do
    before { sign_in_as(god) }

    it "lists the requests with sender, organization, page and state" do
      get valhalla_support_requests_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Dana Member", "Acme", "/member/tickets", "The board loses the column order.")
      expect(Nokogiri::HTML(response.body).at_css("[data-test=valhalla-nav-support]")).to be_present
    end

    it "opens with the empty state when nothing was sent yet" do
      Support::Request.delete_all

      get valhalla_support_requests_path

      expect(response.body).to include("support-requests-empty")
    end

    it "shows one request with everything that came with it" do
      get valhalla_support_request_path(support_request)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("The board loses the column order.", "1440 × 900", "mailto:#{sender.email}")
    end

    it "marks a request handled, and new again" do
      patch valhalla_support_request_path(support_request), params: { handled: "1" }

      expect(support_request.reload).to have_attributes(handled?: true, handled_by: god)

      patch valhalla_support_request_path(support_request), params: { handled: "0" }

      expect(support_request.reload).to have_attributes(handled?: false, handled_by: nil)
    end
  end
end
