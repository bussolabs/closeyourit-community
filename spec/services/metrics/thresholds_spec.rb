# frozen_string_literal: true

require "rails_helper"

# CYRA-341 — il colore di una durata era un giudizio segreto: 150/500ms cablati nel codice, uguali
# per tutti e scritti da nessuna parte. Qui si blinda che le soglie siano un'impostazione del
# progetto, con i valori di sistema come riserva quando il progetto non ha detto niente.
RSpec.describe Metrics::Thresholds do
  let(:project) { create(:project) }

  it "senza override usa le soglie di sistema" do
    expect(described_class.for(project)).to eq(fast: Metrics::Group::FAST_MS, slow: Metrics::Group::MEDIUM_MS)
  end

  it "l'override del progetto vince su entrambe le soglie" do
    project.update!(performance_fast_ms: 50, performance_slow_ms: 200)

    expect(described_class.for(project)).to eq(fast: 50, slow: 200)
  end

  it "un solo override: l'altra soglia resta quella di sistema" do
    project.update!(performance_slow_ms: 2_000)

    expect(described_class.for(project)).to eq(fast: Metrics::Group::FAST_MS, slow: 2_000)
  end

  it "campo lasciato vuoto → torna alla soglia di sistema" do
    project.update!(performance_fast_ms: 80, performance_slow_ms: 900)
    project.update!(performance_fast_ms: "", performance_slow_ms: "")

    expect(described_class.for(project)).to eq(fast: Metrics::Group::FAST_MS, slow: Metrics::Group::MEDIUM_MS)
  end

  # Il form rifiuta lo zero (422), ma un valore già scritto per altra via non deve azzerare la scala.
  it "valore non positivo eredita la soglia di sistema" do
    project.update_column(:preferences,
                          project.preferences.merge("performance_fast_ms" => 0, "performance_slow_ms" => -5))

    expect(described_class.for(project.reload)).to eq(fast: Metrics::Group::FAST_MS, slow: Metrics::Group::MEDIUM_MS)
  end

  # Il form non lo permette (validazione sul modello), ma un valore già scritto o arrivato da un
  # altro canale non deve produrre una fascia ambra a rovescio: la soglia veloce non supera la lenta.
  it "soglia veloce oltre la lenta → si allinea alla lenta" do
    project.update_column(:preferences,
                          project.preferences.merge("performance_fast_ms" => 900, "performance_slow_ms" => 300))

    expect(described_class.for(project.reload)).to eq(fast: 300, slow: 300)
  end

  it "senza progetto ritorna le soglie di sistema (mai un errore in una vista)" do
    expect(described_class.for(nil)).to eq(fast: Metrics::Group::FAST_MS, slow: Metrics::Group::MEDIUM_MS)
  end
end
