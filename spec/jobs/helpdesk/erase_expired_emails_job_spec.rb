# frozen_string_literal: true

require "rails_helper"

# CYRA-940 — a visitor's address is personal data: it expires by itself.
RSpec.describe Helpdesk::EraseExpiredEmailsJob do
  it "erases the addresses past the retention and keeps the recent ones and the messages" do
    old = create(:helpdesk_request, email: "old@example.com", created_at: (Helpdesk::Constants::EMAIL_RETENTION + 1.day).ago)
    recent = create(:helpdesk_request, email: "recent@example.com", created_at: 1.day.ago)

    described_class.perform_now

    expect(old.reload).to have_attributes(email: nil, email_erased?: true)
    expect(old.messages.count).to eq(1)
    expect(recent.reload.email).to eq("recent@example.com")
  end

  it "runs every day" do
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    entry = recurring.fetch("production")["erase_expired_helpdesk_emails"]

    expect(entry).to include("class" => described_class.name)
  end
end
