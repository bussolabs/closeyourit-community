# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# CYRA-587 — La potatura vera: legge cosa c'è (database, connessioni aperte, file, cartelle di lavoro),
# chiede il piano a TestDatabasePruner e lo esegue. Qui si prova la parte che tocca il mondo, e si
# prova con una connessione finta di proposito: una spec che per verificare la pulizia si mettesse a
# cancellare database veri sarebbe lo stesso identico guasto del ticket, scritto nel posto peggiore.
RSpec.describe TestDatabasePruner::Sweep do
  around do |example|
    Dir.mktmpdir("test-database-sweep") do |dir|
      @root = Pathname.new(dir)
      @root.join("storage").mkpath
      example.run
    end
  end

  attr_reader :root

  # Il database di test con cui questa stessa spec sta girando: il nome dipende da TEST_SLOT e dal
  # processo di parallel_tests, quindi lo si chiede alla configurazione invece di scriverlo a mano.
  let(:mine) { ActiveRecord::Base.connection_db_config.database }

  # Il nome che la configurazione userebbe a variabili vuote: è il prefisso su cui la potatura
  # riconosce «questo è uno dei miei». NON si può scriverlo a mano: in CI il database non si chiama
  # come in locale, e un orfano chiamato `closeyourit_test_…` non verrebbe nemmeno preso in
  # considerazione — la spec passava sul portatile e cadeva sui server della build.
  let(:canonical) { mine.delete_suffix("#{ENV['TEST_SLOT']}#{ENV['TEST_ENV_NUMBER']}") }
  let(:orphan) { "#{canonical}_cyra147" }

  # `closeyourit_development` sta qui come cosa che NON è nostra: non porta il prefisso, quindi non
  # deve nemmeno comparire fra i tenuti.
  let(:existing) { [ canonical, mine, orphan, "closeyourit_development" ].uniq }
  let(:busy) { [ mine ] }

  let(:connection) do
    instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).tap do |double|
      allow(double).to receive(:select_values).with(a_string_matching(/pg_database/)).and_return(existing)
      allow(double).to receive(:select_values).with(a_string_matching(/pg_stat_activity/)).and_return(busy)
      allow(double).to receive(:quote_table_name) { |name| %("#{name}") }
      allow(double).to receive(:execute)
    end
  end

  def sweep(dry_run: false, live_names: [])
    described_class.call(connection: connection, root: root, live_names: live_names, dry_run: dry_run)
  end

  describe "butta gli spazi dati abbandonati" do
    it "cancella il database di una lavorazione che non esiste più" do
      sweep

      expect(connection).to have_received(:execute).with(%(DROP DATABASE IF EXISTS "#{orphan}"))
    end

    it "non cancella nient'altro" do
      sweep

      expect(connection).to have_received(:execute).once
    end

    it "cancella i file di prova rimasti indietro" do
      abandoned = root.join("storage/test_cache_cyra147.sqlite3")
      FileUtils.touch(abandoned, mtime: 300.hours.ago.to_time)

      sweep

      expect(abandoned).not_to exist
    end
  end

  # CYAU-182 — «aperta» non è «esistente»: le cartelle di lavoro non vengono rimosse di proposito,
  # quindi quella di una lavorazione finita restava e salvava il suo spazio dati per sempre.
  describe "una cartella di lavoro che non dà più segno di vita" do
    def cartella(nome, eta:)
      percorso = root.join(nome).tap(&:mkpath)
      FileUtils.touch(percorso, mtime: eta.to_time)
      percorso
    end

    # `live_names: nil` fa girare la lettura vera invece di quella passata a mano dagli altri esempi.
    def sweep_con_worktree(percorsi)
      elenco = percorsi.map { |p| "worktree #{p}\n" }.join
      allow(Open3).to receive(:capture2).and_call_original
      allow(Open3).to receive(:capture2).with("git", "worktree", "list", "--porcelain", any_args)
                                        .and_return([ elenco, instance_double(Process::Status, success?: true) ])
      # Nessun commit leggibile in queste cartelle finte: resta la data del file.
      allow(Open3).to receive(:capture2).with("git", "log", "-1", "--format=%cI", any_args)
                                        .and_return([ "", instance_double(Process::Status, success?: false) ])
      described_class.call(connection: connection, root: root, live_names: nil, dry_run: false)
    end

    it "smette di salvare il suo spazio dati" do
      sweep_con_worktree([ cartella("CYRA-147-vecchia", eta: 30.days.ago) ])

      expect(connection).to have_received(:execute).with(%(DROP DATABASE IF EXISTS "#{orphan}"))
    end

    it "ma finché è viva lo salva ancora" do
      sweep_con_worktree([ cartella("CYRA-147-viva", eta: 1.hour.ago) ])

      expect(connection).not_to have_received(:execute)
    end
  end

  describe "non tocca quello che è in uso" do
    it "non tocca l'archivio con cui sta girando in questo momento" do
      sweep

      expect(connection).not_to have_received(:execute).with(%(DROP DATABASE IF EXISTS "#{mine}"))
    end

    it "non tocca gli archivi delle cartelle di lavoro ancora aperte" do
      sweep(live_names: [ "CYRA-147-qualcosa" ])

      expect(connection).not_to have_received(:execute)
    end

    it "non tocca i file usati da poco" do
      fresh = root.join("storage/test_cache_cyra147.sqlite3")
      FileUtils.touch(fresh, mtime: 1.hour.ago.to_time)

      sweep

      expect(fresh).to exist
    end

    # Fra la fotografia e il comando può passare qualche secondo, e in quei secondi una lavorazione
    # può ricollegarsi: PostgreSQL rifiuta il DROP. Il rifiuto è la difesa che ha funzionato — si
    # scrive e si va avanti, non si insiste e non si trascina giù il resto della potatura.
    it "quando PostgreSQL rifiuta perché qualcuno si è ricollegato, lo dice e prosegue" do
      allow(connection).to receive(:execute).and_raise(
        ActiveRecord::StatementInvalid, "database is being accessed by other users"
      )

      expect { @output = sweep }.not_to raise_error
      expect(@output).to include(orphan)
    end
  end

  describe "la prova a vuoto" do
    it "elenca cosa sparirebbe senza cancellare niente" do
      abandoned = root.join("storage/test_cache_cyra147.sqlite3")
      FileUtils.touch(abandoned, mtime: 300.hours.ago.to_time)

      output = sweep(dry_run: true)

      expect(connection).not_to have_received(:execute)
      expect(abandoned).to exist
      expect(output).to include(orphan)
    end
  end

  # Il comando esiste per gli ambienti di prova e basta. In produzione i nomi non combacerebbero
  # comunque con niente, ma una potatura che si limita a "non trovare niente da fare" è una difesa
  # che dipende dai dati: questa dipende dall'ambiente e si vede a colpo d'occhio.
  describe "fuori dagli ambienti di prova" do
    it "si rifiuta di partire" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { sweep }.to raise_error(described_class::Refused, /produzione|sviluppo/i)
      expect(connection).not_to have_received(:execute)
    end
  end
end
