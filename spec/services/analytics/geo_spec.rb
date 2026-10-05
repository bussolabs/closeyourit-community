# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Geo do
  # Reader MaxMind-like iniettato: i test non dipendono dal file GeoLite2 reale (assente in CI).
  let(:reader) do
    instance_double(MaxMind::DB).tap do |r|
      allow(r).to receive(:get).with("203.0.113.9").and_return({ "country" => { "iso_code" => "IT" } })
      allow(r).to receive(:get).with("8.8.8.8").and_return({ "country" => { "iso_code" => "US" } })
      allow(r).to receive(:get).with("10.0.0.1").and_return(nil) # IP privato: nessun record
    end
  end

  describe ".country_code" do
    it "estrae il country iso_code (ISO alpha-2) dall'IP" do
      expect(described_class.country_code("203.0.113.9", reader: reader)).to eq("IT")
      expect(described_class.country_code("8.8.8.8", reader: reader)).to eq("US")
    end

    it "IP senza record → nil" do
      expect(described_class.country_code("10.0.0.1", reader: reader)).to be_nil
    end

    it "IP blank o nil → nil senza interrogare il reader" do
      expect(described_class.country_code("", reader: reader)).to be_nil
      expect(described_class.country_code(nil, reader: reader)).to be_nil
    end

    it "reader assente (DB .mmdb non presente in dev/test) → nil, degrado silenzioso" do
      expect(described_class.country_code("203.0.113.9", reader: nil)).to be_nil
    end

    it "errore del reader (IP malformato, DB corrotto) → nil, mai un'eccezione che rompa l'ingest" do
      boom = instance_double(MaxMind::DB)
      allow(boom).to receive(:get).and_raise(StandardError, "db corrotto")
      expect(described_class.country_code("qualsiasi", reader: boom)).to be_nil
    end
  end

  describe ".default_reader" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "GeoLite2-Country.mmdb") }

    before do
      stub_const("Analytics::Constants::GEOIP_DB_PATH", path)
      described_class.reset_reader!
    end

    after do
      described_class.reset_reader!
      FileUtils.remove_entry(dir)
    end

    it "opens a database downloaded after the start, without a restart (CYRA-914 P10)" do
      expect(described_class.default_reader).to be_nil

      File.binwrite(path, "mmdb")
      fresh = instance_double(MaxMind::DB)
      allow(MaxMind::DB).to receive(:new).with(path, mode: MaxMind::DB::MODE_MEMORY).and_return(fresh)
      travel(described_class::RECHECK_EVERY + 1.second) do
        expect(described_class.default_reader).to eq(fresh)
      end
    end
  end
end
