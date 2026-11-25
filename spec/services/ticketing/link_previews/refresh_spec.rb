# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::LinkPreviews::Refresh, type: :service do
  let(:organization) { create(:organization) }
  let(:url) { "https://www.figma.com/file/abc/Checkout" }
  let(:png) { File.binread(file_fixture("screenshot.png")) }
  let(:page) do
    <<~HTML
      <html><head>
      <meta property="og:title" content="Checkout redesign">
      <meta property="og:site_name" content="Figma">
      <meta property="og:image" content="https://cdn.figma.test/thumb.png">
      </head></html>
    HTML
  end

  # Test hosts do not resolve: a public address, or every visit would look like one to the inside.
  before { allow(NetworkGuard).to receive(:resolve).and_return([ "93.184.216.34" ]) }

  def stub_page(body = page)
    stub_request(:get, url).to_return(status: 200, body:, headers: { "Content-Type" => "text/html" })
  end

  def stub_image(body = png)
    stub_request(:get, "https://cdn.figma.test/thumb.png").to_return(status: 200, body:,
                                                                     headers: { "Content-Type" => "image/png" })
  end

  def refresh(address = url) = described_class.call(organization:, url: address)

  it "keeps title, site and the image in our storage for seven days" do
    stub_page
    stub_image

    preview = refresh

    expect(preview).to be_ready
    expect(preview).to be_card
    expect(preview.title).to eq("Checkout redesign")
    expect(preview.site_name).to eq("Figma")
    expect(preview.image).to be_attached
    expect(preview.image.download.b).to eq(png.b)
    expect(preview.expires_at).to be_within(1.minute).of(7.days.from_now)
  end

  describe "internal addresses (AC-2, AC-5)" do
    it "never visits a link to the internal network and shows no card" do
      internal = stub_request(:get, "http://10.1.2.3/admin")

      preview = refresh("http://10.1.2.3/admin")

      expect(internal).not_to have_been_requested
      expect(preview).to be_failed
      expect(preview).not_to be_card
    end

    it "stops a redirect towards the cloud metadata address" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "http://169.254.169.254/latest/meta-data" })
      metadata = stub_request(:get, "http://169.254.169.254/latest/meta-data")

      expect(refresh).to be_failed
      expect(metadata).not_to have_been_requested
    end

    it "never downloads an image that lives on an internal host" do
      allow(NetworkGuard).to receive(:resolve).with("cdn.figma.test", timeout: anything).and_return([ "192.168.1.20" ])
      stub_page
      image = stub_image

      preview = refresh

      expect(image).not_to have_been_requested
      expect(preview).to be_card
      expect(preview.image).not_to be_attached
    end
  end

  describe "caps and memory (AC-4)" do
    it "reads the page with a 10 second budget and a 1 MB cap, the image with 2 MB" do
      stub_page
      stub_image
      allow(Seo::Fetch).to receive(:call).and_call_original

      refresh

      expect(Seo::Fetch).to have_received(:call).with(hash_including(url:, budget: 10, max_bytes: 1_000_000))
      expect(Seo::Fetch).to have_received(:call).with(hash_including(budget: 10, max_bytes: 2_000_000, binary: true))
    end

    it "a slow page leaves no card and is tried again only after an hour" do
      stub_request(:get, url).to_timeout

      preview = refresh

      expect(preview).to be_failed
      expect(preview.expires_at).to be_within(1.minute).of(1.hour.from_now)
    end

    it "a page heavier than the cap is read only up to the cap" do
      stub_page(page + ("<p>filler</p>" * 100_000))
      stub_image

      preview = refresh

      expect(preview.title).to eq("Checkout redesign")
    end

    it "a second save within the week does not visit the site again" do
      page_stub = stub_page
      stub_image

      refresh
      refresh

      expect(page_stub).to have_been_requested.once
    end

    it "an expired preview is read again" do
      page_stub = stub_page
      stub_image
      refresh.update!(expires_at: 1.minute.ago)

      refresh

      expect(page_stub).to have_been_requested.twice
    end
  end

  it "an image over the cap gives a card with title and site, without image (AC-6)" do
    stub_page
    stub_image("a" * (described_class::IMAGE_MAX_BYTES + 1))

    preview = refresh

    expect(preview).to be_card
    expect(preview.site_name).to eq("Figma")
    expect(preview.image).not_to be_attached
  end

  it "a file that is not a raster image is not kept, whatever its header says" do
    stub_page
    stub_image('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')

    expect(refresh.image).not_to be_attached
  end

  it "a page without a title gives no card (AC-7)" do
    stub_page("<html><head></head><body>Nothing declared</body></html>")

    preview = refresh

    expect(preview).to be_failed
    expect(preview).not_to be_card
  end

  it "keeps previews apart between organizations" do
    page_stub = stub_page
    stub_image
    refresh

    described_class.call(organization: create(:organization), url:)

    expect(page_stub).to have_been_requested.twice
    expect(Ticketing::LinkPreview.where(url:).count).to eq(2)
  end
end
