# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — il modulo che decide QUANDO è successo un evento per i domini a basso rumore temporale
# (Logs/Analytics::Ingest::Normalize). Sbagliare qui non fa fallire l'ingest: fa comparire una riga
# nell'anno 55840 in cima allo stream, che nessuna pagina riesce più a scrollare via.
RSpec.describe Ingest::EpochTime, type: :service do
  # Un mixin si prova sul suo contratto, non attraverso i quattro Normalize che lo includono.
  let(:parser) { Class.new { include Ingest::EpochTime }.new }

  describe "#parse_time" do
    it "epoch in secondi → l'istante corrispondente" do
      expect(parser.parse_time(1_700_000_000)).to eq(Time.zone.at(1_700_000_000))
    end

    it "epoch in millisecondi (Date.now() lato JS) → lo stesso istante, non l'anno 55840" do
      expect(parser.parse_time(1_700_000_000_000)).to eq(Time.zone.at(1_700_000_000))
    end

    it "stringa ISO8601 → l'istante che dichiara" do
      expect(parser.parse_time("2026-03-01T10:00:00Z")).to eq(Time.zone.parse("2026-03-01T10:00:00Z"))
    end

    it "stringa illeggibile → adesso (l'evento si registra lo stesso)" do
      freeze_time do
        expect(parser.parse_time("non è una data")).to eq(Time.current)
      end
    end

    it "timestamp assente → adesso" do
      freeze_time do
        expect(parser.parse_time(nil)).to eq(Time.current)
      end
    end

    it "tipo inatteso (hash) → adesso, nessuna eccezione" do
      freeze_time do
        expect(parser.parse_time({ "at" => 1 })).to eq(Time.current)
      end
    end

    it "istante nel futuro oltre la tolleranza → adesso (orologio del client sballato)" do
      freeze_time do
        expect(parser.parse_time(2.hours.from_now.to_i)).to eq(Time.current)
      end
    end

    it "istante nel futuro DENTRO la tolleranza → si tiene com'è (scarto d'orologio normale)" do
      freeze_time do
        atteso = 30.minutes.from_now
        expect(parser.parse_time(atteso.to_i)).to eq(Time.zone.at(atteso.to_i))
      end
    end

    it "istante nel passato → si tiene com'è, per quanto vecchio" do
      vecchio = Time.zone.parse("2020-01-01T00:00:00Z")
      expect(parser.parse_time(vecchio.to_i)).to eq(vecchio)
    end
  end

  describe "#normalize_epoch (la soglia secondi/millisecondi)" do
    it "sotto la soglia resta com'è: sono secondi" do
      expect(parser.normalize_epoch(described_class::MS_EPOCH_THRESHOLD - 1))
        .to eq(described_class::MS_EPOCH_THRESHOLD - 1)
    end

    it "dalla soglia in su divide per mille: sono millisecondi" do
      expect(parser.normalize_epoch(described_class::MS_EPOCH_THRESHOLD))
        .to eq(described_class::MS_EPOCH_THRESHOLD / 1000.0)
    end
  end

  describe "#clamp_future (la tolleranza per l'orologio del client)" do
    it "esattamente al limite della tolleranza non viene toccato" do
      freeze_time do
        limite = Time.current + described_class::MAX_FUTURE_SKEW
        expect(parser.clamp_future(limite)).to eq(limite)
      end
    end

    it "oltre il limite diventa adesso" do
      freeze_time do
        expect(parser.clamp_future(Time.current + described_class::MAX_FUTURE_SKEW + 1.second))
          .to eq(Time.current)
      end
    end
  end
end
