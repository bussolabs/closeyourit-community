# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la chiave di deduplica di un campione di prestazione: campioni con la stessa firma nello
# stesso progetto formano UN gruppo. Se smettesse di essere stabile, ogni campione aprirebbe un
# gruppo nuovo e la pagina delle prestazioni diventerebbe una lista di righe tutte da una occorrenza.
RSpec.describe Metrics::Fingerprint, type: :service do
  def fp(signature) = described_class.call(signature: signature)

  it "è una stringa di 64 caratteri esadecimali" do
    expect(fp("http.server|GET /checkout")).to match(/\A[0-9a-f]{64}\z/)
  end

  it "la stessa firma dà sempre la stessa chiave" do
    expect(fp("http.server|GET /checkout")).to eq(fp("http.server|GET /checkout"))
  end

  it "firme diverse danno chiavi diverse" do
    expect(fp("http.server|GET /checkout")).not_to eq(fp("http.server|GET /cart"))
  end

  # La firma include già il tipo di misura (lo compone Metrics::Ingest::Normalize): due misure
  # diverse sullo stesso percorso non devono cadere nello stesso gruppo.
  it "lo stesso percorso con tipo di misura diverso è un gruppo diverso" do
    expect(fp("http.server|GET /checkout")).not_to eq(fp("db.query|GET /checkout"))
  end

  it "la firma non viene normalizzata: maiuscole e spazi contano" do
    expect(fp("GET /checkout")).not_to eq(fp("get /checkout"))
    expect(fp("GET /checkout")).not_to eq(fp(" GET /checkout"))
  end

  it "firma assente → chiave calcolabile lo stesso, uguale a quella della firma vuota" do
    expect(fp(nil)).to eq(fp(""))
  end
end
