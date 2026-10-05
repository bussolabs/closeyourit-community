# frozen_string_literal: true

require "rails_helper"

# CYRA-587 — Fino a ieri ogni cartella di lavoro puntava agli STESSI database di test. Due lavorazioni
# aperte insieme si azzeravano lo schema a vicenda: la suite dell'una moriva a metà mentre l'altra
# faceva `db:test:prepare`, e l'errore che ne usciva sembrava un difetto del codice invece che il
# magazzino sparito sotto i piedi.
#
# TEST_ENV_NUMBER non era riusabile per questo: è di parallel_tests, che lo IMPOSTA lui per ciascuno
# dei processi figli (`parallel_rspec -n 3`) sovrascrivendo qualunque valore arrivi da fuori. Serviva
# una seconda variabile che parallel_tests non tocca — TEST_SLOT — e serve che le due si compongano,
# altrimenti i tre processi di una stessa lavorazione tornano a pestarsi fra loro.
RSpec.describe "config/database.yml — lo spazio dati di ogni lavorazione" do
  # Nomi che il progetto usa da sempre quando nessuno dichiara niente: sono il metro dello Scenario 2.
  TODAY = {
    "primary" => "closeyourit_test",
    "cache" => "storage/test_cache.sqlite3",
    "queue" => "closeyourit_queue_test",
    "cable" => "storage/test_cable.sqlite3"
  }.freeze

  # Il file si legge come lo legge Rails: ERB prima, YAML poi. Le variabili sono finte perché questa
  # stessa spec gira DENTRO parallel_rspec, dove TEST_ENV_NUMBER vale davvero "2" o "3": leggere
  # l'ambiente reale renderebbe il risultato dipendente da chi ha lanciato la suite.
  def test_databases(slot: nil, process_number: nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TEST_SLOT").and_return(slot)
    allow(ENV).to receive(:[]).with("TEST_ENV_NUMBER").and_return(process_number)

    rendered = ERB.new(Rails.root.join("config/database.yml").read).result
    YAML.safe_load(rendered, aliases: true).fetch("test").transform_values { |entry| entry.fetch("database") }
  end

  describe "quando nessuno dichiara uno spazio dati" do
    it "usa gli stessi archivi di sempre: è un'aggiunta, non un cambio di comportamento" do
      expect(test_databases).to eq(TODAY)
    end

    it "i processi in parallelo si numerano come hanno sempre fatto" do
      expect(test_databases(process_number: "2")).to eq(
        "primary" => "closeyourit_test2",
        "cache" => "storage/test_cache2.sqlite3",
        "queue" => "closeyourit_queue_test2",
        "cable" => "storage/test_cable2.sqlite3"
      )
    end
  end

  describe "quando una lavorazione dichiara il proprio spazio dati" do
    it "tutti e quattro gli archivi lo portano, non solo i due PostgreSQL" do
      names = test_databases(slot: "_cyra_587")

      expect(names.keys).to match_array(TODAY.keys)
      names.each_value { |name| expect(name).to include("_cyra_587") }
    end

    it "lo spazio dati viene prima del numero di processo, così le due cose si compongono" do
      expect(test_databases(slot: "_cyra_587", process_number: "3")).to eq(
        "primary" => "closeyourit_test_cyra_5873",
        "cache" => "storage/test_cache_cyra_5873.sqlite3",
        "queue" => "closeyourit_queue_test_cyra_5873",
        "cable" => "storage/test_cable_cyra_5873.sqlite3"
      )
    end
  end

  # Il punto di tutto il ticket: nessun archivio in comune. Se anche uno solo dei quattro coincidesse,
  # basterebbe quello a far cadere la suite dell'altra lavorazione.
  it "due lavorazioni diverse non condividono nessun archivio" do
    mine = test_databases(slot: "_cyra_587").values
    yours = test_databases(slot: "_cyra_591").values

    expect(mine & yours).to be_empty
  end

  it "due processi della stessa lavorazione non condividono nessun archivio" do
    first = test_databases(slot: "_cyra_587").values
    second = test_databases(slot: "_cyra_587", process_number: "2").values

    expect(first & second).to be_empty
  end
end
