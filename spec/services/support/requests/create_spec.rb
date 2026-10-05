# frozen_string_literal: true

require "rails_helper"

RSpec.describe Support::Requests::Create do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  def call(body: "The board loses the column order.", client_context: {}, request_details: {})
    described_class.call(account:, organization:, body:, client_context:, request_details:)
  end

  it "saves the message with the listed browser details and what the server knows" do
    result = call(client_context: { "page" => "/member/tickets", "window" => "1440 × 900", "cookie" => "secret" },
                  request_details: { role: "admin", user_agent: "Chrome", request_id: "abc-1" })

    expect(result).to be_ok
    expect(result.value.context).to include("page" => "/member/tickets", "window" => "1440 × 900", "role" => "admin",
                                            "user_agent" => "Chrome", "request_id" => "abc-1")
    expect(result.value.context).not_to have_key("cookie")
  end

  it "cuts an oversized browser detail instead of storing it whole" do
    result = call(client_context: { "page" => "x" * 2_000 })

    expect(result.value.context["page"].length).to eq(Support::Constants::CONTEXT_VALUE_MAX_CHARS)
  end

  it "announces the request by email" do
    expect { call }.to have_enqueued_mail(Support::RequestsMailer, :created)
  end

  it "refuses an empty message and sends nothing" do
    result = nil
    expect { result = call(body: "  ") }.not_to have_enqueued_mail(Support::RequestsMailer, :created)

    expect(result).not_to be_ok
    expect(Support::Request.count).to eq(0)
  end

  it "refuses a message over the limit" do
    expect(call(body: "x" * (Support::Constants::BODY_MAX_CHARS + 1))).not_to be_ok
  end
end
