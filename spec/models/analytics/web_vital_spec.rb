# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::WebVital do
  let(:project) { create(:project) }

  it "accetta solo le metriche che sappiamo leggere" do
    expect(build(:web_vital, project:, metric: "lcp")).to be_valid
    expect(build(:web_vital, project:, metric: "inventata")).not_to be_valid
  end

  # CYRA-538 — il percentile si calcola qui, a query time, e per metrica E dispositivo insieme: un
  # telefono e un computer sono due esperienze diverse dello stesso sito, e mediarle nasconde
  # proprio quella che va male.
  describe ".percentiles" do
    before do
      # Dieci misure da telefono: il p75 cade sul settimo valore ordinato.
      [ 1_000, 1_200, 1_400, 1_600, 1_800, 2_000, 2_400, 2_800, 3_200, 4_000 ].each do |valore|
        create(:web_vital, project:, metric: "lcp", value: valore, device_type: "mobile")
      end
      create(:web_vital, :desktop, project:, metric: "lcp", value: 900)
      create(:web_vital, :desktop, project:, metric: "lcp", value: 1_100)
    end

    it "dà il 75° percentile e quante misure lo sostengono, per metrica e dispositivo" do
      esito = described_class.percentiles(described_class.where(project_id: project.id))

      telefono = esito[[ "lcp", "mobile" ]]
      expect(telefono[:samples]).to eq(10)
      expect(telefono[:p75]).to be_between(2_400, 2_800)

      computer = esito[[ "lcp", "desktop" ]]
      expect(computer[:samples]).to eq(2)
      # Il percentile NON è la media: con due valori sta fra i due, spostato verso l'alto.
      expect(computer[:p75]).to be > 1_000
    end

    it "una sola query, non una per combinazione" do
      query = 0
      contatore = ->(*, payload) { query += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }

      ActiveSupport::Notifications.subscribed(contatore, "sql.active_record") do
        described_class.percentiles(described_class.where(project_id: project.id))
      end

      expect(query).to eq(1)
    end
  end
end
