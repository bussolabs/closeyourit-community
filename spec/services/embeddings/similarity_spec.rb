# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::Similarity do
  describe ".percent" do
    it "traduce la distanza coseno in somiglianza percentuale" do
      expect(described_class.percent(0.0)).to eq(100)
      expect(described_class.percent(0.10)).to eq(90)
      expect(described_class.percent(0.20)).to eq(80)
    end

    it "arrotonda all'intero: la somiglianza è una stima, non una misura di precisione" do
      expect(described_class.percent(0.154)).to eq(85)
      expect(described_class.percent(0.156)).to eq(84)
    end

    it "non scende sotto zero quando i testi sono opposti" do
      expect(described_class.percent(1.4)).to eq(0)
      expect(described_class.percent(2.0)).to eq(0)
    end

    it "torna nil senza distanza: un record non caricato per vicinanza non ha una somiglianza" do
      expect(described_class.percent(nil)).to be_nil
    end
  end

  describe ".score" do
    it "torna la somiglianza come frazione, senza arrotondare" do
      expect(described_class.score(0.104)).to be_within(1e-9).of(0.896)
    end

    it "è la percentuale a decidere, non la frazione: 0,896 vale 90 tondo" do
      # Il confronto fra i simili e la soglia si fa sul numero che si legge in pagina: filtrare
      # sulla frazione grezza scriverebbe «90%» accanto a un ticket che una soglia del 90% scarta.
      expect(described_class.percent(0.104)).to eq(90)
    end
  end

  describe "soglie del suggerimento duplicati" do
    it "ferma la creazione più in alto di quanto suggerisca: il pannello propone, il confronto blocca" do
      expect(Ticketing::Constants::DUPLICATE_GATE_SIMILARITY)
        .to be > Ticketing::Constants::DUPLICATE_PANEL_SIMILARITY
    end
  end
end
