# frozen_string_literal: true

require "rails_helper"

# CYRA-735 — le regole di pulizia del dato in ingresso (data nel futuro, epoch in millisecondi, testo
# troppo lungo, percentuale fuori scala, lista senza tetto) vivono qui e in nessun altro posto.
# Prima stavano copiate in Errors/Servers/Logs/Analytics::Ingest::Normalize: quattro copie della
# stessa espressione, già divergenti (solo Errors si difendeva dall'epoch impossibile).
#
# La REGOLA è una; la MISURA (tolleranza d'orologio, soglia secondi/millisecondi, tetto) resta una
# scelta del dominio e arriva come argomento: gli errori tollerano 5 minuti di scarto, i server e i
# log un'ora, e quei numeri sono deliberatamente diversi.
RSpec.describe Ingest::Normalization, type: :service do
  describe ".clamp_future" do
    it "un istante nel futuro oltre la tolleranza diventa adesso (orologio del client sballato)" do
      freeze_time do
        expect(described_class.clamp_future(2.hours.from_now, skew: 5.minutes)).to eq(Time.current)
      end
    end

    it "esattamente al limite della tolleranza non viene toccato" do
      freeze_time do
        limite = Time.current + 5.minutes
        expect(described_class.clamp_future(limite, skew: 5.minutes)).to eq(limite)
      end
    end

    it "la tolleranza la decide il dominio: un'ora di scarto passa per i server, non per gli errori" do
      freeze_time do
        istante = 30.minutes.from_now
        expect(described_class.clamp_future(istante, skew: 1.hour)).to eq(istante)
        expect(described_class.clamp_future(istante, skew: 5.minutes)).to eq(Time.current)
      end
    end

    it "un istante nel passato si tiene com'è, per quanto vecchio" do
      vecchio = Time.zone.parse("2020-01-01T00:00:00Z")
      expect(described_class.clamp_future(vecchio, skew: 1.hour)).to eq(vecchio)
    end

    it "nil resta nil: chi chiama decide cosa mettere al posto di un istante che non c'è" do
      expect(described_class.clamp_future(nil, skew: 1.hour)).to be_nil
    end
  end

  describe ".epoch_seconds (la soglia secondi/millisecondi)" do
    it "sotto la soglia resta com'è: sono secondi" do
      expect(described_class.epoch_seconds(1_700_000_000, ms_threshold: 1_000_000_000_000))
        .to eq(1_700_000_000)
    end

    it "dalla soglia in su divide per mille: sono millisecondi (Date.now() lato JS)" do
      expect(described_class.epoch_seconds(1_700_000_000_000, ms_threshold: 1_000_000_000_000))
        .to eq(1_700_000_000.0)
    end

    it "la soglia la decide il dominio: lo stesso numero è secondi per uno e millisecondi per l'altro" do
      valore = 500_000_000_000
      expect(described_class.epoch_seconds(valore, ms_threshold: 1_000_000_000_000)).to eq(valore)
      expect(described_class.epoch_seconds(valore, ms_threshold: 100_000_000_000)).to eq(valore / 1000.0)
    end

    it "senza soglia non c'è euristica: il numero è in secondi e resta com'è" do
      expect(described_class.epoch_seconds(1_700_000_000_000)).to eq(1_700_000_000_000)
    end
  end

  describe ".epoch_to_time" do
    it "epoch in secondi → l'istante corrispondente" do
      expect(described_class.epoch_to_time(1_700_000_000, ms_threshold: 1_000_000_000_000))
        .to eq(Time.zone.at(1_700_000_000))
    end

    it "epoch in millisecondi → lo stesso istante, non l'anno 55840" do
      expect(described_class.epoch_to_time(1_700_000_000_000, ms_threshold: 1_000_000_000_000))
        .to eq(Time.zone.at(1_700_000_000))
    end

    # Solo Errors si difendeva da questo: con il modulo condiviso la difesa vale per tutti i canali.
    # Un numero che non è una data non deve far morire il job — morendo perderebbe l'intero batch.
    it "un numero che non è una data → nil, non un'eccezione che perde il dato" do
      expect(described_class.epoch_to_time(Float::INFINITY)).to be_nil
      expect(described_class.epoch_to_time(-Float::INFINITY)).to be_nil
      expect(described_class.epoch_to_time(Float::NAN)).to be_nil
    end

    # Un epoch enorme ma rappresentabile non solleva: diventa un istante lontanissimo, e a fermarlo è
    # il clamp del futuro che ogni canale applica subito dopo. Le due difese sono in fila, non alternative.
    it "un epoch assurdo ma rappresentabile passa di qui e lo ferma il clamp del futuro" do
      freeze_time do
        istante = described_class.epoch_to_time(1e300)

        expect(istante).to be_present
        expect(described_class.clamp_future(istante, skew: 1.hour)).to eq(Time.current)
      end
    end
  end

  describe ".clean_text" do
    it "tronca al tetto di caratteri richiesto" do
      expect(described_class.clean_text("a" * 50, 10)).to eq("a" * 10)
    end

    it "toglie i byte nulli (Postgres li rifiuta in text e jsonb)" do
      expect(described_class.clean_text("a#{0.chr}b", 10)).to eq("ab")
    end

    it "ripara i byte che non sono testo valido (journald è una sorgente sporca)" do
      pulito = described_class.clean_text((+"ok").force_encoding("ASCII-8BIT") << 255.chr, 10)

      expect(pulito).to be_valid_encoding
      expect(pulito).to start_with("ok")
    end

    it "un valore assente diventa testo vuoto, mai nil: la colonna è di testo" do
      expect(described_class.clean_text(nil, 10)).to eq("")
    end

    it "un valore non testuale viene reso come testo" do
      expect(described_class.clean_text(42, 10)).to eq("42")
    end
  end

  describe ".numeric_percentage" do
    it "arrotonda a due decimali" do
      expect(described_class.numeric_percentage(12.3456)).to eq(12.35)
    end

    it "riporta dentro la scala i valori fuori scala" do
      expect(described_class.numeric_percentage(140)).to eq(100.0)
      expect(described_class.numeric_percentage(-3)).to eq(0.0)
    end

    it "il tetto lo decide il dominio: le connessioni del database possono superare il 100%" do
      expect(described_class.numeric_percentage(180.5, max: 999.99)).to eq(180.5)
      expect(described_class.numeric_percentage(5_000, max: 999.99)).to eq(999.99)
    end

    it "ciò che non è un numero → nil: 'non lo so' non è 'zero'" do
      expect(described_class.numeric_percentage(nil)).to be_nil
      expect(described_class.numeric_percentage("87")).to be_nil
    end
  end

  describe ".rows" do
    it "cappa la lista e scarta gli elementi che il blocco rifiuta" do
      lista = [ { "n" => "a" }, "spazzatura", { "n" => "b" }, { "n" => "c" } ]

      risultato = described_class.rows(lista, 2) do |item|
        next unless item.is_a?(Hash)

        item["n"]
      end

      expect(risultato).to eq(%w[a b])
    end

    it "ciò che non è una lista → nil (sezione assente nel filo)" do
      expect(described_class.rows(nil, 5) { |item| item }).to be_nil
      expect(described_class.rows({ "n" => "a" }, 5) { |item| item }).to be_nil
    end

    it "lista che si svuota dopo il filtro → nil, non una lista vuota da persistere" do
      expect(described_class.rows([ "spazzatura" ], 5) { |item| item if item.is_a?(Hash) }).to be_nil
    end
  end
end
