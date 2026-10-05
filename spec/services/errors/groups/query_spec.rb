# frozen_string_literal: true

require "rails_helper"

# CYRA-738 — la lista dei gruppi d'errore la chiedono due canali (le app a token bearer e la riga di
# comando). La domanda ai dati sta qui, una volta sola: ordine, filtro di stato e preload
# dell'assegnatario valgono per entrambi, e una correzione fatta qui arriva a tutti e due.
RSpec.describe Errors::Groups::Query do
  let(:project) { create(:project) }

  it "ordina dal visto più di recente" do
    vecchio = create(:error_group, project:, last_seen_at: 2.hours.ago)
    nuovo   = create(:error_group, project:, last_seen_at: 1.minute.ago)

    expect(described_class.call(project:).to_a).to eq([ nuovo, vecchio ])
  end

  it "resta dentro il progetto chiesto" do
    mio = create(:error_group, project:)
    create(:error_group, project: create(:project, organization: project.organization))

    expect(described_class.call(project:).to_a).to eq([ mio ])
  end

  it "filtra per stato quando lo stato esiste" do
    create(:error_group, project:, status: :unresolved)
    risolto = create(:error_group, project:, status: :resolved)

    expect(described_class.call(project:, status: "resolved").to_a).to eq([ risolto ])
  end

  it "ignora uno stato che non esiste invece di svuotare la lista" do
    gruppo = create(:error_group, project:)

    expect(described_class.call(project:, status: "inventato").to_a).to eq([ gruppo ])
    expect(described_class.call(project:, status: nil).to_a).to eq([ gruppo ])
  end

  # La lentezza che il canale delle app aveva e quello della riga di comando no: l'assegnatario
  # finisce nel risultato di ogni riga, quindi va caricato con la lista, non una riga per volta.
  it "carica l'assegnatario insieme alla lista" do
    assignee = create(:account)
    create(:membership, account: assignee, organization: project.organization, role: :member)
    create(:error_group, project:, assignee:)

    gruppi = described_class.call(project:).to_a

    expect(gruppi.first.association(:assignee)).to be_loaded
  end
end
