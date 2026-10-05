# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::DiskForecast do
  let(:host) { create(:server_host) }
  let(:now) { Time.current }

  # Un campione ogni 2 ore per 7 giorni (84 punti > minimo 48).
  def seed_samples(start_pct:, pct_per_day:)
    rows = (0...84).map do |i|
      at = now - 7.days + (i * 2).hours
      days = (at - (now - 7.days)) / 86_400.0
      { host_id: host.id, organization_id: host.organization_id, recorded_at: at,
        cpu_pct: 1.0, data_volume_disk_pct: (start_pct + days * pct_per_day).round(2),
        created_at: now }
    end
    # CYRA-750 — la tabella è divisa a fette: la scrittura in blocco passa dal gemello (vedi
    # PartitionedTable), che dichiara la chiave primaria com'è sul database.
    Servers::Sample::Bulk.insert_all(rows)
  end

  it "stima i giorni alla saturazione da una crescita lineare" do
    # 60% sette giorni fa, +2%/giorno → oggi ~74%, saturazione in ~13 giorni.
    seed_samples(start_pct: 60, pct_per_day: 2)

    forecast = described_class.call(host: host, now: now).value

    expect(forecast[:days]).to be_within(1.0).of(13.0)
    expect(forecast[:slope_pct_per_day]).to be_within(0.1).of(2.0)
    expect(forecast[:current_pct]).to be_within(0.5).of(74.0)
  end

  it "volume fermo → nessuna stima" do
    seed_samples(start_pct: 88, pct_per_day: 0)

    expect(described_class.call(host: host, now: now).value).to be_nil
  end

  it "volume che si svuota → nessuna stima" do
    seed_samples(start_pct: 80, pct_per_day: -1)

    expect(described_class.call(host: host, now: now).value).to be_nil
  end

  it "pochi punti (host nuovo) → nessuna stima" do
    create(:server_sample, host: host, recorded_at: 1.hour.ago, data_volume_disk_pct: 50)

    expect(described_class.call(host: host, now: now).value).to be_nil
  end

  it "host senza volume dati (pct sempre nil) → nessuna stima" do
    3.times do |i|
      create(:server_sample, host: host, recorded_at: (i + 1).hours.ago, data_volume_disk_pct: nil)
    end

    expect(described_class.call(host: host, now: now).value).to be_nil
  end
end
