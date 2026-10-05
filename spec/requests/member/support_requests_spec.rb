# frozen_string_literal: true

require "rails_helper"

# CYRA-935 — the Support button in the footer: the screen waits under every member page, and the
# message is saved with the page the person was on.
RSpec.describe "Member::SupportRequests", type: :request do
  let(:org) { create(:organization, name: "Acme") }
  let(:account) { create(:account) }

  before do
    create(:membership, account:, organization: org, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "puts the Support button in the footer and the screen under the page" do
    get member_todo_lists_path

    page = Nokogiri::HTML(response.body)
    expect(page.at_css("[data-test=member-footer] [data-test=footer-support]")).to be_present
    expect(page.at_css("[data-test=member-menu-support]")).to be_present
    screen = page.at_css("[data-test=support-screen]")
    expect(screen["hidden"]).not_to be_nil
    expect(screen.at_css("turbo-frame#support-request [data-test=support-body]")).to be_present
    expect(screen.at_css("[data-test=support-context-organization]").text).to eq("Acme")
  end

  it "saves the request with the browser details and answers inside the frame" do
    expect do
      post member_support_requests_path, params: { body: "The board loses the column order.",
                                                   context: { page: "/member/tickets", window: "1440 × 900", evil: "x" } }
    end.to change(Support::Request, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("support-sent", "turbo-frame")
    saved = Support::Request.last
    expect(saved).to have_attributes(account:, organization: org, body: "The board loses the column order.")
    expect(saved.context).to include("page" => "/member/tickets", "window" => "1440 × 900", "role" => "member")
    expect(saved.context).not_to have_key("evil")
  end

  it "shows the error in the frame and keeps the text when the message is too long" do
    long = "x" * (Support::Constants::BODY_MAX_CHARS + 1)

    post member_support_requests_path, params: { body: long }

    expect(response).to have_http_status(:unprocessable_content)
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("turbo-frame#support-request [data-test=support-error]")).to be_present
    expect(page.at_css("[data-test=support-body]").text.strip).to eq(long)
    expect(Support::Request.count).to eq(0)
  end

  it "lists the person's own requests with their state, and nobody else's" do
    Support::Request.create!(account:, organization: org, body: "Mine, still open", context: { "page" => "/member/tickets" })
    Support::Request.create!(account:, organization: org, body: "Mine, taken care of", handled_at: Time.current)
    Support::Request.create!(account: create(:account), organization: org, body: "Somebody else")

    get member_support_requests_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Mine, still open", "Mine, taken care of", "/member/tickets")
    expect(response.body).not_to include("Somebody else")
    rows = Nokogiri::HTML(response.body).css("[data-test=support-mine-row]")
    expect(rows.map { |row| row.text.squish }).to match([ a_string_including("Handled"), a_string_including("Open") ])
  end

  it "links the list from the support screen" do
    get member_todo_lists_path

    link = Nokogiri::HTML(response.body).at_css("[data-test=support-screen] [data-test=support-mine]")
    expect(link["href"]).to eq(member_support_requests_path)
  end
end
