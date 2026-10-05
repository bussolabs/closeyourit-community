# frozen_string_literal: true

require "rails_helper"

# CYRA-738 — gli elenchi di riferimento (stati, priorità, piattaforme, ambienti, stati di una cella)
# li servono i due canali a token con la stessa identica domanda: solo gli attivi, nell'ordine
# scelto dall'organizzazione. Nove controller che scrivevano la stessa riga, ora una sola.
RSpec.describe Types::Lookups::Query do
  let(:organization) { create(:organization) }

  it "conosce gli elenchi dei due canali" do
    expect(described_class::COLLECTIONS).to match_array(
      %i[environments platforms ticket_priorities ticket_statuses feature_statuses]
    )
  end

  it "lascia fuori quelli non attivi" do
    attiva = create(:platform, organization:, active: true, position: 1)
    create(:platform, organization:, active: false, position: 2)

    expect(described_class.call(organization:, collection: :platforms).to_a).to include(attiva)
    expect(described_class.call(organization:, collection: :platforms).count).to eq(1)
  end

  it "rispetta la posizione scelta dall'organizzazione" do
    seconda = create(:ticket_status, organization:, position: 20, label: "Bravo")
    prima   = create(:ticket_status, organization:, position: 10, label: "Alfa")

    elenco = described_class.call(organization:, collection: :ticket_statuses).to_a

    expect(elenco.index(prima)).to be < elenco.index(seconda)
  end

  it "resta dentro l'organizzazione chiesta" do
    mia = create(:environment, organization:)
    create(:environment, organization: create(:organization))

    expect(described_class.call(organization:, collection: :environments).to_a).to include(mia)
    expect(described_class.call(organization:, collection: :environments).count).to eq(1)
  end

  # Il nome dell'elenco lo sceglie il canale, mai chi chiama da fuori: un nome inventato è un errore
  # di scrittura del codice e deve farsi sentire subito, non tornare una lista vuota.
  it "un elenco che non esiste si ferma subito" do
    expect { described_class.call(organization:, collection: :inventati) }
      .to raise_error(ArgumentError, /inventati/)
  end
end
