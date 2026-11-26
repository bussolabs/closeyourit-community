# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — texts crossing between an issue and a ticket.
RSpec.describe Github::Issues::Text do
  let(:url) { "https://github.com/bussolabs/app/issues/1" }

  it "keeps a text that fits as it is" do
    expect(described_class.comment("Breve", url)).to eq([ "Breve", false ])
  end

  it "cuts a long comment within the ticket's ceiling and links the original" do
    body, cut = described_class.comment("x" * 1000, url)

    expect(cut).to be(true)
    expect(body.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS
    expect(body).to include(url)
  end

  it "gives an issue without text a description that can be saved" do
    description, cut = described_class.description("   ", url)

    expect(description).to include(url)
    expect(cut).to be(false)
  end

  it "strips the file links CloseYourIt appended to the issue" do
    body = "Testo\n\n#{described_class::ATTACHMENTS_MARKER}\n- [log.txt](https://example.com/f/1)"

    expect(described_class.without_attachments(body)).to eq("Testo")
  end
end
