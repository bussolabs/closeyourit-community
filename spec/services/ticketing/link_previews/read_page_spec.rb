# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::LinkPreviews::ReadPage, type: :service do
  it "reads the Open Graph tags first and makes the image address absolute" do
    html = <<~HTML
      <html><head><title>Fallback</title>
      <meta property="og:title" content="Checkout redesign">
      <meta property="og:site_name" content="Figma">
      <meta property="og:description" content="The new checkout flow">
      <meta property="og:image" content="/thumbs/abc.png">
      </head></html>
    HTML

    data = described_class.call(html:, url: "https://www.figma.com/file/abc")

    expect(data).to eq(title: "Checkout redesign", site_name: "Figma", description: "The new checkout flow",
                       image_url: "https://www.figma.com/thumbs/abc.png")
  end

  it "falls back on the page title and on the host for the site" do
    data = described_class.call(html: "<html><head><title> Release notes </title></head></html>",
                                url: "https://www.docs.test/notes")

    expect(data[:title]).to eq("Release notes")
    expect(data[:site_name]).to eq("docs.test")
    expect(data[:image_url]).to be_nil
  end

  it "has no title when the page declares none" do
    expect(described_class.call(html: "<html><body>hi</body></html>", url: "https://docs.test/")[:title]).to be_nil
  end

  it "treats a title equal to the site name as no title (a private file)" do
    html = '<html><head><title>Figma</title><meta property="og:site_name" content="Figma"></head></html>'

    expect(described_class.call(html:, url: "https://www.figma.com/file/private")[:title]).to be_nil
  end
end
