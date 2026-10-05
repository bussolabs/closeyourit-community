# frozen_string_literal: true

require "rails_helper"
require "rubocop"

# CYRA-805 — il tetto alla complessità vale per il codice nuovo, non per quello già scritto.
#
# Accendere il controllo su tutto il repository avrebbe voluto dire riscrivere subito diciassette
# file per poter consegnare qualunque altra cosa. Accenderlo per il codice nuovo e mettere quei
# diciassette in un elenco di eccezioni costa una riga oggi e blocca la crescita da domani. La
# condizione perché funzioni è una sola: che l'elenco possa solo accorciarsi. Un elenco a cui si può
# aggiungere non è un'eccezione, è l'interruttore spento con più passaggi.
#
# `bin/rubocop` prende le offese vere nella CI (`lint`). Qui si presidia ciò che rubocop non può
# dirsi da sé: che il controllo resti acceso, che l'elenco non cresca e che non tenga righe morte.
RSpec.describe "Il tetto alla complessità delle funzioni (CYRA-805)" do
  TETTO_COMPLESSITA_CYRA805 = 15
  TETTO_ANNIDAMENTO_CYRA805 = 3

  COP_COMPLESSITA_CYRA805 = %w[Metrics/CyclomaticComplexity Metrics/PerceivedComplexity].freeze

  # I file già sopra soglia il giorno in cui il controllo è stato acceso (misura del 2026-09-07 con
  # `Max: 15`). Il confronto è per SOTTRAZIONE: togliere un file è il lavoro dei ticket fratelli,
  # aggiungerne uno è la deriva che questa prova esiste per fermare.
  SOPRA_SOGLIA_AL_2026_09_07_CYRA805 = %w[
    app/controllers/concerns/member/tickets/detail.rb
    app/jobs/knowledge/review_page_job.rb
    app/models/agents/workflow.rb
    app/models/servers/sample.rb
    app/services/agents/hosts/register.rb
    app/services/agents/leases/acquire.rb
    app/services/agents/limits/reserve.rb
    app/services/agents/ticket_queues/claim.rb
    app/services/agents/workflows/in_flight.rb
    app/services/agents/workflows/phase_resolver.rb
    app/services/authorization/visible_scope.rb
    app/services/home/approvals/queue.rb
    app/services/knowledge/create_page.rb
    app/services/secrets/github/secrets_json.rb
    app/services/servers/database_inventory.rb
    app/services/servers/ingest/normalize.rb
    app/services/ticketing/update_ticket.rb
  ].freeze

  # Una funzione con più rami del tetto, scritta in un file che nessuna eccezione copre: è il codice
  # nuovo dello scenario 1.
  FUNZIONE_TROPPO_RAMIFICATA_CYRA805 = <<~RUBY
    def call(valore)
      #{(1..20).map { |number| "return :ramo#{number} if valore == #{number}" }.join("\n  ")}
      nil
    end
  RUBY

  FUNZIONE_SEMPLICE_CYRA805 = <<~RUBY
    def call(valore)
      return :vuoto if valore.blank?
      return :negativo if valore.negative?

      :ok
    end
  RUBY

  let(:configurazione) do
    RuboCop::ConfigStore.new.tap { |store| store.options_config = Rails.root.join(".rubocop.yml").to_s }
  end

  # Un percorso che non esiste ancora: la configurazione si risolve dalla cartella, e nessuna
  # eccezione può nominare un file che nessuno ha ancora scritto.
  let(:file_nuovo) { Rails.root.join("app/services/cyra805/funzione_appena_scritta.rb").to_s }

  # Le sole due misure in gioco, prese dal registro globale: nominarle per stringa tiene la prova
  # legata al nome che si scrive in `.rubocop.yml`.
  def registro
    RuboCop::Cop::Registry.new(COP_COMPLESSITA_CYRA805.map { |nome| RuboCop::Cop::Registry.global.find_by_cop_name(nome) })
  end

  # Quello che rubocop segnalerebbe davvero su quel file: la squadra tiene conto sia dello
  # spegnimento sia delle eccezioni, ed è l'unico modo perché la prova fallisca se il controllo
  # resta spento.
  def segnalazioni(sorgente, file)
    regole = configurazione.for_file(file)
    analizzato = RuboCop::ProcessedSource.new(sorgente, regole.target_ruby_version, file)

    RuboCop::Cop::Team.mobilize(registro, regole, {}).investigate(analizzato).offenses
  end

  # La misura nuda, presa ignorando le eccezioni: serve a sapere se un file escluso è ancora sopra
  # soglia o se qualcuno lo ha già semplificato.
  def misura_cruda(nome, sorgente, file)
    regole = configurazione.for_file(file)
    cop = RuboCop::Cop::Registry.global.find_by_cop_name(nome).new(regole)
    analizzato = RuboCop::ProcessedSource.new(sorgente, regole.target_ruby_version, file)
    # Il sorgente da solo non basta: senza queste due il cop non sa leggere i `rubocop:disable`
    # scritti nel file e scoppia sulla prima segnalazione.
    analizzato.config = regole
    analizzato.registry = RuboCop::Cop::Registry.global

    RuboCop::Cop::Commissioner.new([ cop ], [], raise_error: true).investigate(analizzato).offenses
  end

  def esclusi_da(nome)
    Array(configurazione.for_file(file_nuovo).for_cop(nome)["Exclude"])
      .map { |percorso| Pathname.new(percorso.to_s).relative_path_from(Rails.root).to_s }
  end

  describe "il controllo è acceso" do
    it "misura i rami di ogni funzione con lo stesso tetto" do
      COP_COMPLESSITA_CYRA805.each do |nome|
        regole = configurazione.for_file(file_nuovo).for_cop(nome)

        expect(regole["Enabled"]).to be(true), "#{nome} è spento: il codice nuovo non viene misurato"
        expect(regole["Max"]).to eq(TETTO_COMPLESSITA_CYRA805), "#{nome} misura con un tetto diverso"
      end
    end

    it "limita anche quanto si annidano i blocchi" do
      regole = configurazione.for_file(file_nuovo).for_cop("Metrics/BlockNesting")

      expect(regole["Enabled"]).to be(true)
      expect(regole["Max"]).to eq(TETTO_ANNIDAMENTO_CYRA805)
    end

    # Nessun file lo violava il giorno dell'accensione: un'eccezione qui sarebbe nata già morta.
    it "non fa eccezioni sull'annidamento" do
      expect(esclusi_da("Metrics/BlockNesting")).to be_empty
    end
  end

  describe "scenario 1 — codice nuovo" do
    it "segnala una funzione con troppi rami" do
      segnalate = segnalazioni(FUNZIONE_TROPPO_RAMIFICATA_CYRA805, file_nuovo).map(&:cop_name)

      expect(segnalate).to match_array(COP_COMPLESSITA_CYRA805)
    end

    it "lascia in pace una funzione con pochi rami" do
      expect(segnalazioni(FUNZIONE_SEMPLICE_CYRA805, file_nuovo)).to be_empty
    end
  end

  describe "scenario 2 — codice già scritto" do
    # Un file della baseline può essere cancellato o rinominato: non ha più niente da segnalare, e
    # leggerlo lo stesso farebbe morire la prova con un errore che non nomina il vero motivo.
    it "non segnala i file che erano già sopra soglia" do
      ancora_segnalati = SOPRA_SOGLIA_AL_2026_09_07_CYRA805.select { |file| Rails.root.join(file).exist? }.reject do |file|
        percorso = Rails.root.join(file).to_s
        segnalazioni(File.read(percorso), percorso).empty?
      end

      expect(ancora_segnalati).to be_empty,
                                  "questi file erano già sopra soglia prima dell'accensione e la " \
                                  "farebbero fallire: #{ancora_segnalati.join(', ')}"
    end
  end

  describe "l'elenco delle eccezioni" do
    it "è lo stesso per entrambe le misure" do
      cicli, percepita = COP_COMPLESSITA_CYRA805.map { |nome| esclusi_da(nome) }

      expect(cicli).to match_array(percepita)
    end

    it "si può solo accorciare" do
      COP_COMPLESSITA_CYRA805.each do |nome|
        aggiunti = esclusi_da(nome) - SOPRA_SOGLIA_AL_2026_09_07_CYRA805

        expect(aggiunti).to be_empty, <<~MESSAGGIO
          Questi file sono stati aggiunti alle eccezioni di #{nome} dopo l'accensione del controllo:

          #{aggiunti.join("\n")}

          L'elenco tiene solo i file che erano già sopra soglia il 2026-09-07. Una funzione nuova
          troppo ramificata si semplifica, non si aggiunge qui.
        MESSAGGIO
      end
    end

    it "non nomina file che non esistono più" do
      fantasmi = esclusi_da(COP_COMPLESSITA_CYRA805.first).reject { |file| Rails.root.join(file).exist? }

      expect(fantasmi).to be_empty,
                          "eccezioni rimaste dopo la cancellazione del file: #{fantasmi.join(', ')}"
    end

    it "non tiene file ormai sistemati" do
      # Le eccezioni su file spariti le nomina la prova qui sopra, con il suo messaggio: qui si
      # guardano solo quelle che un file ce l'hanno ancora.
      esclusi = esclusi_da(COP_COMPLESSITA_CYRA805.first).select { |file| Rails.root.join(file).exist? }

      sistemati = esclusi.select do |file|
        percorso = Rails.root.join(file).to_s
        sorgente = File.read(percorso)
        COP_COMPLESSITA_CYRA805.all? { |nome| misura_cruda(nome, sorgente, percorso).empty? }
      end

      expect(sistemati).to be_empty, <<~MESSAGGIO
        Questi file stanno sotto il tetto e non hanno più bisogno dell'eccezione:

        #{sistemati.join("\n")}

        Vanno tolti dall'elenco: un'eccezione che non copre più niente fa sembrare complicato del
        codice che qualcuno ha già semplificato, e la prossima volta nessuno lo ricontrolla.
      MESSAGGIO
    end
  end
end
