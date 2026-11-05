# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Ingest::Record do
  let(:project) { create(:project) }
  let(:context) do
    {
      visitor_hash: Digest::SHA256.hexdigest("v"), browser: "Chrome", os: "macOS",
      device_type: "desktop", browser_version: "126", os_version: "10.15", country_code: "IT"
    }
  end

  def item(over = {})
    { "event_id" => SecureRandom.uuid, "hostname" => "www.example.test", "path" => "/foo" }.merge(over)
  end

  it "inserisce un batch in un solo insert_all e ritorna il numero di righe scritte" do
    result = described_class.call(project:, payload: [ item, item ], context:)
    expect(result).to be_ok
    expect(result.value).to eq(2)
    expect(project.analytics_pageviews.count).to eq(2)
  end

  it "applica il context (visitor_hash/browser/os/device/versioni) a tutte le righe del batch" do
    described_class.call(project:, payload: [ item ], context:)
    row = project.analytics_pageviews.sole
    expect(row.visitor_hash).to eq(context[:visitor_hash])
    expect(row.browser).to eq("Chrome")
    expect(row.os).to eq("macOS")
    expect(row.device_type).to eq("desktop")
    expect(row.browser_version).to eq("126")
    expect(row.os_version).to eq("10.15")
    expect(row.country_code).to eq("IT")
  end

  it "persiste utm_term/content e screen_class dal payload normalizzato" do
    described_class.call(
      project:,
      payload: [ item("utm_term" => "scarpe", "utm_content" => "banner-a", "screen_width" => 1920) ],
      context:
    )
    row = project.analytics_pageviews.sole
    expect(row.utm_term).to eq("scarpe")
    expect(row.utm_content).to eq("banner-a")
    expect(row.screen_class).to eq("desktop")
  end

  it "è idempotente su (project_id, event_id): i duplicati vengono skippati" do
    fixed = item("event_id" => "pv-fisso")
    expect(described_class.call(project:, payload: [ fixed ], context:).value).to eq(1)
    expect(described_class.call(project:, payload: [ fixed ], context:).value).to eq(0)
    expect(project.analytics_pageviews.count).to eq(1)
  end

  it "scarta gli item non-Hash o senza hostname/path" do
    result = described_class.call(
      project:, payload: [ item, "spazzatura", { "path" => "/senza-host" }, { "hostname" => "x.test" } ], context:
    )
    expect(result.value).to eq(1)
  end

  it "batch interamente scartato → Result.ok(0) senza insert" do
    expect(described_class.call(project:, payload: [ {} ], context:).value).to eq(0)
    expect(Analytics::Pageview.count).to eq(0)
  end

  describe ".acceptable?" do
    it "richiede un Hash con hostname e path presenti" do
      expect(described_class.acceptable?(item)).to be(true)
      expect(described_class.acceptable?({ "hostname" => "x.test" })).to be(false)
      expect(described_class.acceptable?({ "path" => "/x" })).to be(false)
      expect(described_class.acceptable?("no")).to be(false)
    end
  end
end
