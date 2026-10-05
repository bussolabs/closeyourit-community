# frozen_string_literal: true

require "rails_helper"

# CYRA-738 — le stesse liste (errori, prestazioni, log, rilasci, copertura, traffico, elenchi di
# riferimento) le servono due canali a token: quello delle app e quello della riga di comando. La
# domanda ai dati era scritta due volte, e le due copie erano già andate a fondo separate: la lista
# degli errori caricava l'assegnatario da una parte e non dall'altra, e quella senza era la lenta.
#
# Qui si guarda il sorgente, non il comportamento: nessuno dei due canali ricostruisce la lista a
# mano. Le prove di comportamento restano i request spec dei due canali.
RSpec.describe "Le liste dei due canali a token partono dalla stessa domanda", type: :model do
  # Ogni voce: il controller e la domanda condivisa che deve nominare. Sette liste, due canali
  # ciascuna (gli elenchi di riferimento sono quattro dalle app e cinque dalla riga di comando).
  gemelli = {
    "app/controllers/api/v1/error_groups_controller.rb" => "Errors::Groups::Query",
    "app/controllers/cli/v1/error_groups_controller.rb" => "Errors::Groups::Query",
    "app/controllers/api/v1/metric_groups_controller.rb" => "Metrics::Groups::Query",
    "app/controllers/cli/v1/metric_groups_controller.rb" => "Metrics::Groups::Query",
    "app/controllers/api/v1/log_entries_controller.rb" => "Logs::Entries::Query",
    "app/controllers/cli/v1/log_entries_controller.rb" => "Logs::Entries::Query",
    "app/controllers/api/v1/releases_controller.rb" => "Projects::Releases::Query",
    "app/controllers/cli/v1/releases_controller.rb" => "Projects::Releases::Query",
    "app/controllers/api/v1/coverage_reports_controller.rb" => "Projects::CoverageReports::Query",
    "app/controllers/cli/v1/projects/coverage_reports_controller.rb" => "Projects::CoverageReports::Query",
    "app/controllers/api/v1/analytics_controller.rb" => "Analytics::ChannelSnapshot",
    "app/controllers/cli/v1/analytics_controller.rb" => "Analytics::ChannelSnapshot",
    "app/controllers/api/v1/types/environments_controller.rb" => "Types::Lookups::Query",
    "app/controllers/api/v1/types/platforms_controller.rb" => "Types::Lookups::Query",
    "app/controllers/api/v1/types/ticket_priorities_controller.rb" => "Types::Lookups::Query",
    "app/controllers/api/v1/types/ticket_statuses_controller.rb" => "Types::Lookups::Query",
    "app/controllers/cli/v1/types/environments_controller.rb" => "Types::Lookups::Query",
    "app/controllers/cli/v1/types/feature_statuses_controller.rb" => "Types::Lookups::Query",
    "app/controllers/cli/v1/types/platforms_controller.rb" => "Types::Lookups::Query",
    "app/controllers/cli/v1/types/ticket_priorities_controller.rb" => "Types::Lookups::Query",
    "app/controllers/cli/v1/types/ticket_statuses_controller.rb" => "Types::Lookups::Query"
  }.freeze

  # Le grafie con cui la lista si costruisce a mano: se una ricompare in un controller gemello, la
  # seconda copia è tornata e la prossima correzione arriverà a un canale solo.
  a_mano = [
    /\.error_groups(?:\.includes\([^)]*\))?\.recent/,
    /\.metric_groups\.recent/,
    /\.logs_entries\.recent/,
    /\.releases\.(?:recent|order)/,
    /\.coverage_reports\.order/,
    /\.active\.ordered/,
    /Analytics::Query\.new/
  ].freeze

  it "sono le sette liste in doppia copia del ticket, non una di meno" do
    expect(gemelli.values.uniq.size).to eq(7)
    expect(gemelli.keys.size).to eq(21)
  end

  gemelli.each do |percorso, domanda|
    it "#{percorso} passa da #{domanda}" do
      expect(Rails.root.join(percorso).read).to include(domanda)
    end
  end

  it "nessun canale ricostruisce la lista a mano" do
    scoperti = gemelli.keys.select do |percorso|
      sorgente = Rails.root.join(percorso).read
      a_mano.any? { |grafia| sorgente.match?(grafia) }
    end

    expect(scoperti).to be_empty, <<~MESSAGGIO
      Questi controller riscrivono la lista invece di chiederla alla domanda condivisa:

      #{scoperti.map { |percorso| "  #{percorso}" }.join("\n")}
    MESSAGGIO
  end
end
