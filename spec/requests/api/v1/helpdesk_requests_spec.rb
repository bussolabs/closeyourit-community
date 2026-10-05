# frozen_string_literal: true

require "rails_helper"

# CYRA-940 — the door a visitor's help desk request comes in through.
RSpec.describe "Api::V1::HelpdeskRequests", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, helpdesk_enabled: true) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
  let(:issued) { Projects::Tokens::Issue.call(project:, name: "Site", host: "shop.example.com", environment:).value }
  let(:public_key) { issued[:token].public_key }
  let(:safari) do
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " \
      "Version/17.0 Mobile/15E148 Safari/604.1"
  end
  let(:headers) do
    { "X-Sentry-Auth" => "Sentry sentry_key=#{public_key}", "CONTENT_TYPE" => "application/json",
      "HTTP_USER_AGENT" => safari, "REMOTE_ADDR" => "203.0.113.9" }
  end

  def send_request(to: project, extra_headers: {}, **body)
    post "/api/v1/projects/#{to.id}/helpdesk_requests", params: body.to_json, headers: headers.merge(extra_headers)
  end

  it "stores the message with the page and the browser family, never the address it came from" do
    send_request(message: "I cannot pay by card.", email: "anna@example.com",
                 page_url: "https://shop.example.com/cart", session_id: "abc123")

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.dig("data", "accepted")).to eq(1)
    request = Helpdesk::Request.last
    expect(request).to have_attributes(project_id: project.id, status: "received", email: "anna@example.com",
                                       page_url: "https://shop.example.com/cart", session_id: "abc123",
                                       browser: "Safari", device_type: "mobile", summary: "I cannot pay by card.")
    expect(request.messages.map { |m| [ m.direction, m.body ] }).to eq([ [ "inbound", "I cannot pay by card." ] ])
    expect(request.attributes.values.join(" ")).not_to include("203.0.113.9")
  end

  it "keeps the email encrypted in the table" do
    send_request(message: "Help", email: "anna@example.com")

    stored = Helpdesk::Request.connection.select_value("SELECT email FROM helpdesk_requests")
    expect(stored).not_to include("anna@example.com")
  end

  it "accepts a request with no email" do
    send_request(message: "Where do I change my password?")

    expect(response).to have_http_status(:accepted)
    expect(Helpdesk::Request.last.email).to be_nil
  end

  it "drops tags from the message" do
    send_request(message: "Hello <script>alert(1)</script><b>there</b>")

    expect(Helpdesk::Message.last.body).to eq("Hello alert(1)there")
  end

  it "sends no email at all" do
    expect { send_request(message: "Help", email: "stranger@example.com") }
      .not_to change { ActionMailer::Base.deliveries.size }
  end

  describe "what is refused" do
    it "refuses an empty message" do
      send_request(message: "  ", email: "anna@example.com")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-HELPDESK-001")
      expect(Helpdesk::Request.count).to eq(0)
    end

    it "refuses a message over the limit" do
      send_request(message: "a" * (Helpdesk::Constants::BODY_MAX_CHARS + 1))

      expect(response.parsed_body.dig("error", "code")).to eq("R422-HELPDESK-001")
    end

    it "refuses an email that is not an address" do
      send_request(message: "Help", email: "not-an-address")

      expect(response.parsed_body.dig("error", "code")).to eq("R422-HELPDESK-001")
      expect(Helpdesk::Request.count).to eq(0)
    end

    it "refuses a project with the help desk switched off" do
      project.update!(helpdesk_enabled: false)
      send_request(message: "Help")

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-HELPDESK-001")
    end

    it "refuses a site that is not among the allowed ones" do
      project.update!(allowed_origins: [ "https://shop.example.com" ])
      send_request(message: "Help", extra_headers: { "Origin" => "https://evil.example.net" })

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-INGEST-002")
      expect(Helpdesk::Request.count).to eq(0)
    end

    it "refuses the key of another project" do
      other = create(:project, organization:, helpdesk_enabled: true)
      send_request(message: "Help", to: other)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("R404-HELPDESK-001")
    end

    it "refuses a request with no credential" do
      post "/api/v1/projects/#{project.id}/helpdesk_requests", params: { message: "Help" }.to_json,
                                                              headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "bots" do
    it "answers a filled trap field like a success and stores nothing" do
      send_request(message: "Buy followers", website: "https://spam.example")

      expect(response).to have_http_status(:accepted)
      expect(Helpdesk::Request.count).to eq(0)
    end

    it "stores nothing for a crawler" do
      send_request(message: "Help", extra_headers: { "HTTP_USER_AGENT" => "Googlebot/2.1 (+http://www.google.com/bot.html)" })

      expect(response).to have_http_status(:accepted)
      expect(Helpdesk::Request.count).to eq(0)
    end
  end
end
