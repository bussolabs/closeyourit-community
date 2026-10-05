# frozen_string_literal: true

require "rails_helper"

# CYRA-738 — i due canali a token guardano insiemi di log diversi (le app vedono il progetto del
# codice, la riga di comando tutti i progetti visibili) ma fanno la stessa identica domanda: ordine
# dal più recente e gli stessi tre filtri. L'insieme di partenza lo passa il canale, il resto è qui.
RSpec.describe Logs::Entries::Query do
  let(:project) { create(:project) }
  let(:scope) { Logs::Entry.where(project:) }

  it "ordina dal più recente" do
    vecchio = create(:log_entry, project:, occurred_at: 2.hours.ago)
    nuovo   = create(:log_entry, project:, occurred_at: 1.minute.ago)

    expect(described_class.call(scope:).to_a).to eq([ nuovo, vecchio ])
  end

  it "filtra per livello quando il livello esiste" do
    create(:log_entry, project:, level: :info)
    errore = create(:log_entry, project:, level: :error)

    expect(described_class.call(scope:, level: "error").to_a).to eq([ errore ])
  end

  it "ignora un livello che non esiste invece di svuotare la lista" do
    voce = create(:log_entry, project:)

    expect(described_class.call(scope:, level: "inventato").to_a).to eq([ voce ])
  end

  it "filtra per traccia e per ambiente" do
    tracciata = create(:log_entry, project:, trace_id: "abc", environment: "staging")
    create(:log_entry, project:, trace_id: "xyz", environment: "production")

    expect(described_class.call(scope:, trace_id: "abc").to_a).to eq([ tracciata ])
    expect(described_class.call(scope:, environment: "staging").to_a).to eq([ tracciata ])
  end

  it "un filtro vuoto non filtra" do
    voce = create(:log_entry, project:, trace_id: "abc")

    expect(described_class.call(scope:, trace_id: "", environment: nil).to_a).to eq([ voce ])
  end
end
