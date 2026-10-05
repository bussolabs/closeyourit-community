# frozen_string_literal: true

require "rails_helper"

RSpec.describe Support::RequestsMailer, type: :mailer do
  let(:organization) { create(:organization, name: "Acme") }
  let(:account) { create(:account, name: "Dana Member", email: "dana@example.com") }
  let(:support_request) do
    Support::Request.create!(account:, organization:, body: "The board loses the column order.",
                             context: { "page" => "/member/tickets", "version" => "v1 · abc1234" })
  end

  around do |example|
    previous = ENV[Support::Constants::RECIPIENT_ENV]
    example.run
  ensure
    ENV[Support::Constants::RECIPIENT_ENV] = previous
  end

  it "goes to the configured support address, with the sender as reply-to" do
    ENV[Support::Constants::RECIPIENT_ENV] = "help@example.com"

    mail = described_class.created(support_request)

    expect(mail.to).to eq([ "help@example.com" ])
    expect(mail.reply_to).to eq([ "dana@example.com" ])
    expect(mail.subject).to include("Dana Member")
  end

  it "falls back to the god accounts when no address is configured" do
    ENV.delete(Support::Constants::RECIPIENT_ENV)
    god = create(:account, god: true)

    expect(described_class.created(support_request).to).to eq([ god.email ])
  end

  it "carries the message, the page and a link to the request, in html and text" do
    ENV[Support::Constants::RECIPIENT_ENV] = "help@example.com"
    mail = described_class.created(support_request)

    [ mail.html_part.decoded, mail.text_part.decoded ].each do |part|
      expect(part).to include("The board loses the column order.", "/member/tickets", "/valhalla/support/#{support_request.id}")
    end
  end
end
