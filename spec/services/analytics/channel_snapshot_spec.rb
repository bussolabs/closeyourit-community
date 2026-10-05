# frozen_string_literal: true

require "rails_helper"

# CYRA-738 — la fotografia del traffico che i due canali a token servono era montata due volte, con
# la stessa lista di filtri ammessi ricopiata in entrambi i controller. Qui c'è un montaggio solo.
RSpec.describe Analytics::ChannelSnapshot do
  let(:project) { create(:project) }

  before { create_list(:pageview, 2, project:, path: "/home") }

  it "torna la fotografia completa del progetto" do
    snapshot = described_class.call(project:)

    expect(snapshot[:summary][:pageviews]).to eq(2)
    expect(snapshot).to include(:timeseries, :top_pages, :breakdowns, :goals)
  end

  it "applica i filtri ammessi" do
    create(:pageview, project:, path: "/prezzi")

    expect(described_class.call(project:, filters: { "path" => "/home" })[:summary][:pageviews]).to eq(2)
  end

  # I filtri arrivano dai parametri della richiesta: qui dentro passa solo quello che l'elenco
  # ammette, così un parametro inventato non diventa una condizione sulla lettura.
  it "scarta i filtri fuori elenco e quelli vuoti invece di fidarsi dei parametri" do
    snapshot = described_class.call(
      project:, filters: { "controller" => "analytics", "path" => "", "browser" => nil }
    )

    expect(snapshot[:summary][:pageviews]).to eq(2)
  end

  it "un periodo inventato ricade su quello di partenza invece di svuotare la fotografia" do
    expect(described_class.call(project:, range: "mai")[:summary][:pageviews]).to eq(2)
  end
end
