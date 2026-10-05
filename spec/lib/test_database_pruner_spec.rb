# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# CYRA-587 — Da quando ogni lavorazione ha il proprio spazio dati (TEST_SLOT), gli spazi restano lì
# anche quando la lavorazione è finita da mesi: ne erano rimasti 42. Servono buttati, ma una potatura
# che sbaglia è molto peggio del disordine che risolve: far sparire il magazzino a una suite che sta
# girando è esattamente il guasto che il ticket voleva togliere di mezzo.
#
# Quindi qui la domanda non è «cosa posso buttare» ma «cosa NON posso toccare», e le risposte sono
# quattro, indipendenti: c'è qualcuno collegato adesso; è un archivio di parallel_tests; la cartella
# di lavoro esiste ancora; i file di quello spazio sono stati toccati da poco. Basta UNA a salvare.
# Ogni difesa può solo tenere di più, mai buttare di più: è il verso giusto in cui sbagliare.
RSpec.describe TestDatabasePruner do
  CANONICAL_DATABASES = %w[closeyourit_test closeyourit_queue_test].freeze

  around do |example|
    Dir.mktmpdir("test-database-pruner") do |dir|
      @storage = Pathname.new(dir)
      example.run
    end
  end

  attr_reader :storage

  let(:now) { Time.zone.parse("2026-08-17 12:00:00") }
  let(:canonical_files) { %w[test_cache.sqlite3 test_cable.sqlite3].map { |name| storage.join(name) } }

  # Crea un file di prova con l'età che serve: l'età è l'unica cosa che dice se uno spazio dati è
  # ancora frequentato — PostgreSQL, sui database, non la sa proprio.
  def sqlite(name, age_in_hours:)
    path = storage.join(name)
    FileUtils.touch(path, mtime: (now - (age_in_hours * 3600)).to_time)
    path
  end

  def plan(databases: [], busy_databases: [], files: [], live_names: [])
    described_class.plan(
      databases: databases,
      busy_databases: busy_databases,
      files: files,
      canonical_databases: CANONICAL_DATABASES,
      canonical_files: canonical_files,
      live_names: live_names,
      now: now
    )
  end

  describe "gli abbandonati vengono rimossi" do
    it "butta gli spazi dati di lavorazioni che non esistono più" do
      result = plan(databases: %w[closeyourit_test_cyra147 closeyourit_queue_test_cyra147])

      expect(result.databases).to contain_exactly("closeyourit_test_cyra147", "closeyourit_queue_test_cyra147")
    end

    # Sono i più insidiosi: sembrano processi di parallel_tests ma il numero è un codice di ticket
    # scritto a mano in TEST_ENV_NUMBER, com'era l'unico modo di isolarsi prima di questo ticket.
    it "butta anche gli spazi numerati a mano, che nessun parallel_tests avrebbe mai prodotto" do
      result = plan(databases: %w[closeyourit_test153 closeyourit_test220])

      expect(result.databases).to contain_exactly("closeyourit_test153", "closeyourit_test220")
    end

    it "butta i file di prova rimasti indietro" do
      old = sqlite("test_cache_cyra147.sqlite3", age_in_hours: 300)

      expect(plan(files: [ old ]).files).to contain_exactly(old)
    end
  end

  describe "quelli in uso restano" do
    it "non tocca gli archivi di chi lavora senza dichiarare uno spazio dati" do
      result = plan(databases: CANONICAL_DATABASES)

      expect(result.databases).to be_empty
    end

    it "non tocca gli archivi dei processi di parallel_tests" do
      result = plan(databases: %w[closeyourit_test2 closeyourit_test3 closeyourit_queue_test2])

      expect(result.databases).to be_empty
    end

    it "non tocca chi ha qualcuno collegato adesso" do
      result = plan(
        databases: %w[closeyourit_test_cyra524 closeyourit_test_cyra147],
        busy_databases: %w[closeyourit_test_cyra524]
      )

      expect(result.databases).to contain_exactly("closeyourit_test_cyra147")
    end

    # Una suite in corso tiene aperto il primary, non necessariamente tutti e quattro: buttare gli
    # altri tre mentre gira è lo stesso identico guasto di prima, solo arrivato da un'altra strada.
    it "salva tutta la famiglia di uno spazio dati, non solo l'archivio collegato" do
      result = plan(
        databases: %w[closeyourit_test_cyra524 closeyourit_queue_test_cyra524],
        busy_databases: %w[closeyourit_test_cyra524]
      )

      expect(result.databases).to be_empty
    end

    it "non tocca gli spazi delle cartelle di lavoro ancora aperte" do
      result = plan(
        databases: %w[closeyourit_test_cyra591 closeyourit_test_cyra147],
        live_names: [ "CYRA-591-scheda-lavorazione" ]
      )

      expect(result.databases).to contain_exactly("closeyourit_test_cyra147")
    end

    # La cartella di lavoro può chiamarsi come il ticket senza combaciare carattere per carattere, e
    # i processi paralleli aggiungono la loro cifra in fondo allo spazio: il confronto guarda la
    # somiglianza, non l'uguaglianza. Chi somiglia si tiene.
    it "riconosce lo spazio della cartella aperta anche nei suoi processi paralleli" do
      result = plan(databases: %w[closeyourit_test_cyra5912], live_names: [ "CYRA-591-scheda-lavorazione" ])

      expect(result.databases).to be_empty
    end

    # Trovato lanciando la potatura a vuoto sulla macchina vera: `closeyourit_testcyra79` risultava
    # salvo per colpa di una cartella che si chiama `cyra-prod`, cioè per le quattro lettere del
    # prodotto e nient'altro. Somigliarsi vuol dire arrivare fino al numero della lavorazione: senza
    # quello sono due cose diverse che iniziano uguale, e tenerle tutte vanifica la potatura.
    it "non scambia per viva una cartella che condivide solo il nome del prodotto" do
      result = plan(databases: %w[closeyourit_testcyra79], live_names: [ "cyra-prod" ])

      expect(result.databases).to contain_exactly("closeyourit_testcyra79")
    end

    it "non tocca i file usati da poco" do
      fresh = sqlite("test_cache_cyra591.sqlite3", age_in_hours: 1)

      expect(plan(files: [ fresh ]).files).to be_empty
    end

    # Il caso della lavorazione in pausa fra due comandi: nessuna connessione aperta in quel momento,
    # eppure è viva. I suoi file l'hanno vista passare pochi minuti fa e la coprono.
    it "un file appena usato salva anche i database dello stesso spazio dati" do
      fresh = sqlite("test_cache_cyra591.sqlite3", age_in_hours: 1)

      result = plan(databases: %w[closeyourit_test_cyra591 closeyourit_queue_test_cyra591], files: [ fresh ])

      expect(result.databases).to be_empty
    end
  end

  describe "quello che non è suo non lo guarda nemmeno" do
    it "ignora i database di sviluppo e quelli di altri progetti" do
      result = plan(
        databases: %w[closeyourit_development closeyourit_queue_development bugtome_rails_test postgres]
      )

      expect(result.databases).to be_empty
      expect(result.kept.map(&:name)).not_to include("closeyourit_development")
    end

    it "ignora i file che non sono archivi di prova" do
      other = storage.join("development_cache.sqlite3")
      FileUtils.touch(other, mtime: (now - (300 * 3600)).to_time)

      expect(plan(files: [ other ]).files).to be_empty
    end
  end

  describe "dice cosa ha tenuto e perché" do
    it "ogni archivio risparmiato porta scritto il motivo" do
      result = plan(databases: %w[closeyourit_test closeyourit_test2 closeyourit_test_cyra524],
                    busy_databases: %w[closeyourit_test_cyra524])

      expect(result.kept.map(&:name)).to contain_exactly("closeyourit_test", "closeyourit_test2",
                                                         "closeyourit_test_cyra524")
      expect(result.kept.map(&:reason)).to all(be_present)
    end

    it "il riepilogo elenca cosa sparisce, non solo quanti sono" do
      result = plan(databases: %w[closeyourit_test_cyra147])

      expect(result.message).to include("closeyourit_test_cyra147")
    end

    it "quando non c'è niente da buttare lo dice e basta" do
      result = plan(databases: CANONICAL_DATABASES)

      expect(result).to be_empty
      expect(result.message).to include("Nessuno spazio dati")
    end
  end
end
