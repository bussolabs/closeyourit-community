# frozen_string_literal: true

require "rails_helper"

# CYRA-551 — la copertura costa, e va pagata solo dove serve davvero.
#
# Il conto misurato su questa suite: il tracking line+branch rallenta il run, e alla fine il report
# (HTML su ~37.000 righe tracciate + LCOV) aggiunge una decina di secondi a QUALUNQUE esecuzione,
# anche a un singolo file da 9 secondi. Chi sviluppa lo paga a ogni giro del ciclo rosso-verde senza
# guardare il risultato nemmeno una volta.
#
# Nei controlli automatici invece la copertura È il gate (≥90 linee/branch) e non si tocca. Ma negli
# SHARD il report non lo legge nessuno: il template raccoglie soltanto `coverage/.resultset.json` e
# il job successivo (`rake coverage:collate`) genera HTML e LCOV una volta sola sul risultato unito.
# Generarli in ogni shard è lo stesso lavoro moltiplicato per otto e buttato via.
#
# Queste spec presidiano la politica, non l'implementazione: `enabled?` e `formatters_for` sono
# funzioni pure, così si possono interrogare senza riconfigurare SimpleCov nel processo in corso —
# riconfigurarlo qui spegnerebbe il report del run che le sta eseguendo, cioè il gate stesso.
RSpec.describe SimplecovConfiguration do
  describe ".enabled?" do
    it "sta ferma quando nessuno ha chiesto la copertura" do
      expect(described_class.enabled?({})).to be(false)
    end

    it "si accende quando la si chiede esplicitamente" do
      expect(described_class.enabled?({ "COVERAGE" => "1" })).to be(true)
    end

    it "si accende sempre nei controlli automatici, che la usano come gate" do
      expect(described_class.enabled?({ "CI" => "true" })).to be(true)
    end

    it "si accende nel job che collaziona gli shard, che dichiara solo il gate" do
      expect(described_class.enabled?({ "COVERAGE_ENFORCE" => "1" })).to be(true)
    end

    # Una variabile lasciata a vuoto o a zero nella shell è un "no": senza questo, un `COVERAGE=`
    # dimenticato in un `.envrc` rimetterebbe in conto i dieci secondi a ogni run, in silenzio.
    it "legge come spenta una variabile vuota, a zero o a false" do
      expect(described_class.enabled?({ "COVERAGE" => "" })).to be(false)
      expect(described_class.enabled?({ "COVERAGE" => "0" })).to be(false)
      expect(described_class.enabled?({ "CI" => "false" })).to be(false)
    end
  end

  describe ".formatters_for" do
    it "produce HTML e LCOV quando il report ha un lettore" do
      expect(described_class.formatters_for({ "CI" => "true" })).to contain_exactly(
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::LcovFormatter
      )
    end

    # Il resultset grezzo viene scritto lo stesso: SimpleCov lo salva in `SimpleCov.result`, prima
    # e indipendentemente dai formatter (simplecov 1.0, `result_processing.rb`). Senza formatter
    # salta solo la resa, che nello shard nessuno apre.
    it "non produce nessun report dentro uno shard, dove il template prende solo il resultset" do
      expect(described_class.formatters_for({ "CI" => "true", "TEST_SHARD" => "3" })).to be_empty
    end
  end

  describe ".command_name_for" do
    it "non nomina il run quando non è uno shard" do
      expect(described_class.command_name_for({})).to be_nil
    end

    it "dà un nome distinto a ogni shard, o il merge ne terrebbe uno solo" do
      expect(described_class.command_name_for({ "TEST_SHARD" => "3" })).to eq("rspec-shard-3")
    end

    # Suite parallela locale: parallel_tests numera i processi con TEST_ENV_NUMBER e lascia il primo
    # a stringa vuota. Senza un nome per processo, gli otto risultati si sovrascrivono a vicenda.
    it "distingue anche i processi della suite parallela locale" do
      expect(described_class.command_name_for({ "TEST_ENV_NUMBER" => "4" })).to eq("rspec-shard-4")
      expect(described_class.command_name_for({ "TEST_ENV_NUMBER" => "" })).to eq("rspec-shard-1")
    end
  end

  describe ".start!" do
    it "non avvia niente quando la copertura non è stata chiesta" do
      expect(SimpleCov).not_to receive(:start)

      described_class.start!({})
    end

    it "avvia il tracking quando la copertura serve" do
      # `apply` resta fuori gioco: applicarlo davvero riconfigurerebbe il SimpleCov che sta
      # misurando questo stesso run.
      allow(described_class).to receive(:apply)
      allow(SimpleCov).to receive(:start)

      described_class.start!({ "COVERAGE" => "1" })

      expect(SimpleCov).to have_received(:start).with("rails")
    end

    it "nomina il run quando è uno shard" do
      allow(described_class).to receive(:apply)
      allow(SimpleCov).to receive(:start)
      allow(SimpleCov).to receive(:command_name)

      described_class.start!({ "CI" => "true", "TEST_SHARD" => "2" })

      expect(SimpleCov).to have_received(:command_name).with("rspec-shard-2")
    end

    # CYRA-550 — la configurazione arriva da `.simplecov`, che simplecov carica da sé durante il
    # `require`. Se quel file non venisse trovato (root diversa, checkout parziale) il tracking
    # partirebbe SENZA filtri e SENZA soglia, e il gate direbbe di sì senza aver guardato niente:
    # è il guasto che questo ticket è venuto a chiudere, non uno da reintrodurre da un'altra porta.
    it "applica comunque la configurazione, invece di fidarsi che qualcuno l'abbia già fatto" do
      allow(described_class).to receive(:apply)
      allow(SimpleCov).to receive(:start)

      described_class.start!({ "COVERAGE" => "1" })

      expect(described_class).to have_received(:apply).with({ "COVERAGE" => "1" })
    end
  end

  describe ".configure!" do
    it "non tocca la configurazione quando la copertura non è stata chiesta" do
      expect(described_class).not_to receive(:apply)

      described_class.configure!({})
    end

    it "configura quando la copertura serve" do
      allow(described_class).to receive(:apply)

      described_class.configure!({ "CI" => "true" })

      expect(described_class).to have_received(:apply).with({ "CI" => "true" })
    end
  end

  # Il gate della copertura vive nei controlli automatici e lì deve restare: `.simplecov` deve
  # limitarsi a chiamare la politica, non a decidere per conto suo.
  #
  # CYRA-550 — e da simplecov 1.0 deve anche limitarsi a CONFIGURARE: `SimpleCov.start` chiamato da
  # `.simplecov` è deprecato e in una prossima versione non avvierà più niente. L'avvio vero sta in
  # `spec_helper`, sotto.
  describe "il file .simplecov" do
    let(:simplecov_file) { Rails.root.join(".simplecov").read }

    it "delega la decisione alla politica invece di configurare la copertura da sé" do
      expect(simplecov_file).to include("SimplecovConfiguration.configure!")
    end

    it "non avvia la copertura da dentro un file di sola configurazione" do
      expect(simplecov_file).not_to match(/^\s*SimpleCov\.start/)
      expect(simplecov_file).not_to include("SimplecovConfiguration.start!")
    end
  end

  # CYRA-550 — il tracking deve partire prima di QUALUNQUE codice applicativo, e `spec_helper` è il
  # primo file che rspec carica (`.rspec` contiene `--require spec_helper`). Metterlo in
  # `rails_helper` non basta: gli spec che non hanno bisogno di Rails non ci arrivano mai, e in un
  # run fatto solo di quelli la copertura non veniva misurata affatto — nessun rapporto a schermo e
  # uscita 0 anche col gate acceso.
  describe "il file spec/spec_helper.rb" do
    let(:spec_helper_file) { Rails.root.join("spec/spec_helper.rb").read }

    it "avvia la copertura, che è il posto dove simplecov 1.0 vuole lo start" do
      expect(spec_helper_file).to include("SimplecovConfiguration.start!")
    end

    it "la avvia prima di caricare qualsiasi altra cosa" do
      first_statement = spec_helper_file.lines.grep_v(/\A\s*(#|\z)/).first

      expect(first_statement).to include("simplecov_configuration")
    end
  end

  # CYRA-550 — le deprecazioni non sono rumore da tollerare: le chiamate che le emettono spariranno,
  # e quando spariranno la configurazione smetterà di essere applicata in silenzio, esattamente come
  # è già successo con lo start dentro `.simplecov`. Qui si presidia il sorgente, non il
  # comportamento: applicare davvero la politica riconfigurerebbe il run che la sta misurando.
  describe "le chiamate a SimpleCov" do
    let(:policy_source) { Rails.root.join("lib/simplecov_configuration.rb").read }

    it "usa `skip` invece di `add_filter`, che è deprecato" do
      expect(policy_source).not_to include("add_filter")
      expect(policy_source).to include("skip")
    end

    it "usa `cover` invece di `track_files`, che è deprecato" do
      expect(policy_source).not_to include("track_files")
      expect(policy_source).to include("cover ")
    end
  end

  # CYRA-550 — il vecchio marcatore `# :nocov:` è deprecato: simplecov lo legge ancora ma stampa una
  # riga di avviso per OGNI file che lo contiene, e quando smetterà di leggerlo quelle esclusioni
  # rientreranno tutte nel conteggio di colpo, facendo cadere il gate su codice che nessuno ha
  # toccato. Sono ventidue file: senza questo controllo il ventitreesimo rientra al primo copia-incolla.
  describe "i marcatori di esclusione nel codice" do
    let(:offending_files) do
      Rails.root.glob("{app,lib}/**/*.rb").select do |file|
        file.each_line.any? { |line| line.match?(/\A\s*#\s*:nocov:/) }
      end
    end

    it "usa la forma corrente `# simplecov:disable` / `# simplecov:enable`" do
      expect(offending_files).to be_empty, lambda {
        elenco = offending_files.map { |file| file.relative_path_from(Rails.root) }.join("\n  ")
        "Marcatore `# :nocov:` deprecato in:\n  #{elenco}\n" \
          "Sostituiscilo con `# simplecov:disable` (apertura) e `# simplecov:enable` (chiusura)."
      }
    end
  end
end
