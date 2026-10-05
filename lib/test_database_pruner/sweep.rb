# frozen_string_literal: true

require "open3"

class TestDatabasePruner
  # CYRA-587 — La potatura vera e propria: raccoglie la fotografia (quali database esistono, chi è
  # collegato, quali file di prova ci sono, quali cartelle di lavoro sono aperte), chiede il piano a
  # TestDatabasePruner ed esegue. Sta in una classe e non dentro il file .rake perché un comando che
  # cancella database va provato, e i file .rake non si provano: si eseguono e basta.
  #
  # I nomi da cui parte non sono scritti qui: se li fa dare dalla configurazione di test corrente,
  # togliendo il suffisso che le variabili le hanno appena messo (`closeyourit_test_cyra_5872` meno
  # `_cyra_5872` fa `closeyourit_test`). Così una rinomina del progetto non lascia indietro una
  # potatura che cerca ancora i nomi vecchi — o peggio, che li trova su un'altra installazione.
  class Sweep
    Refused = Class.new(StandardError)

    ALLOWED_ENVIRONMENTS = %w[development test].freeze

    # Difesa doppia sul nome: i nomi arrivano già da pg_database e già filtrati dal piano, ma questa
    # è l'unica riga del progetto che scrive DROP DATABASE — qui l'eccesso di prudenza costa nulla.
    SAFE_DATABASE_NAME = /\A[a-z0-9_]+\z/

    # CYAU-182 — dopo quanto una cartella di lavoro smette di valere come «aperta». Larga di
    # proposito: due settimane senza un file toccato NÉ un commit sono una lavorazione finita, e
    # anche sbagliando qui restano in piedi le altre tre difese.
    WORKTREE_GRACE = 14 * 24 * 60 * 60

    EXISTING_DATABASES = "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
    BUSY_DATABASES = "SELECT DISTINCT datname FROM pg_stat_activity WHERE datname IS NOT NULL"

    def self.call(...) = new(...).call

    def initialize(connection: nil, root: Rails.root, live_names: nil, dry_run: false, now: Time.current)
      @connection = connection
      @root = Pathname.new(root.to_s)
      @live_names = live_names
      @dry_run = dry_run
      @now = now
    end

    def call
      refuse_outside_test_environments!

      plan = build_plan
      return [ plan.message, "Prova a vuoto: non ho cancellato niente." ].join("\n") if @dry_run
      return plan.message if plan.empty?

      [ plan.message, "", *plan.databases.map { |name| drop(name) }, *plan.files.map { |path| delete(path) } ]
        .join("\n")
    end

    private

    def connection = @connection ||= ActiveRecord::Base.connection

    def refuse_outside_test_environments!
      return if ALLOWED_ENVIRONMENTS.include?(Rails.env)

      raise Refused, "Gli spazi dati di prova si potano solo in sviluppo o durante le prove: qui " \
                     "l'ambiente è #{Rails.env}, e in produzione questo comando non ha niente da fare."
    end

    def build_plan
      TestDatabasePruner.plan(
        databases: connection.select_values(EXISTING_DATABASES),
        # Agli archivi collegati si aggiungono sempre quelli di QUESTO processo: è l'unico caso in cui
        # la potatura potrebbe segare il ramo su cui è seduta, e non dipende da cosa risponde il
        # database.
        busy_databases: connection.select_values(BUSY_DATABASES) + current_databases,
        files: storage_files,
        canonical_databases: current_databases.map { |name| name.delete_suffix(current_suffix) },
        canonical_files: current_files.map { |path| canonical_file(path) },
        live_names: live_names,
        now: @now
      )
    end

    # Quello che le variabili hanno attaccato ai nomi in questo processo: TEST_SLOT più il numero di
    # processo di parallel_tests, nello stesso ordine in cui config/database.yml li compone.
    def current_suffix = "#{ENV['TEST_SLOT']}#{ENV['TEST_ENV_NUMBER']}"

    def test_configurations
      @test_configurations ||= ActiveRecord::Base.configurations.configs_for(env_name: "test")
    end

    def current_databases
      @current_databases ||= test_configurations.select { |config| config.adapter.include?("postgresql") }
                                                .map(&:database)
    end

    def current_files
      @current_files ||= test_configurations.reject { |config| config.adapter.include?("postgresql") }
                                            .map { |config| @root.join(config.database) }
    end

    def canonical_file(path)
      return path if current_suffix.empty?

      Pathname.new(path.to_s.sub(/#{Regexp.escape(current_suffix)}(\.sqlite3)\z/, '\1'))
    end

    def storage_files
      current_files.map(&:dirname).uniq.flat_map { |dir| dir.children.select(&:file?) }
    end

    # I nomi delle cartelle di lavoro aperte. Se git non risponde (non è un repository, non è
    # installato) resta l'elenco vuoto: si perde una delle quattro difese, non la potatura.
    #
    # CYAU-182 — «aperta» non è «esistente». Le cartelle di lavoro non vengono rimosse di proposito,
    # per non cancellare lavoro che nessuno ha ancora unito: quindi una cartella di una lavorazione
    # finita mesi fa restava lì e continuava a salvare il suo spazio dati per sempre. Si accumulavano
    # senza che nessuna delle quattro difese potesse scadere.
    #
    # Qui una cartella conta come aperta solo se dà ancora segno di vita. Le altre tre difese restano
    # intatte e valgono comunque: chi è collegato adesso, gli archivi di parallel_tests e i file
    # toccati nelle ultime due ore si salvano lo stesso, qualunque cosa dica questa.
    def live_names
      @live_names ||= worktree_paths.select { |path| recent?(path) }.map { |path| File.basename(path) }
    end

    def worktree_paths
      listing, status = Open3.capture2("git", "worktree", "list", "--porcelain",
                                       chdir: Rails.root.to_s, err: File::NULL)
      status.success? ? listing.scan(/^worktree (.+)$/).flatten : []
    end

    # Segno di vita: l'ultima volta che qualcuno ha toccato la cartella oppure ci ha committato
    # dentro. Servono entrambi — c'è chi lascia lavoro non committato per giorni (la cartella è
    # fresca, l'ultimo commit è vecchio) e chi committa e non tocca più niente.
    def recent?(path)
      [ directory_mtime(path), last_commit_at(path) ].compact.max&.then { |t| (@now - t) < WORKTREE_GRACE }
    end

    def directory_mtime(path)
      File.mtime(path)
    rescue SystemCallError
      nil
    end

    def last_commit_at(path)
      out, status = Open3.capture2("git", "log", "-1", "--format=%cI", chdir: path, err: File::NULL)
      status.success? && out.present? ? Time.zone.parse(out.strip) : nil
    rescue StandardError
      nil
    end

    def drop(name)
      return " ! #{name}: il nome non ha la forma di un database di prova, non lo tocco" unless name.match?(SAFE_DATABASE_NAME)

      connection.execute("DROP DATABASE IF EXISTS #{connection.quote_table_name(name)}")
      " - #{name}: buttato"
    rescue ActiveRecord::StatementInvalid => e
      # Il caso tipico è «is being accessed by other users»: fra la fotografia e il comando qualcuno
      # si è ricollegato. È il rifiuto che protegge una lavorazione ripartita adesso — si prende per
      # buono e si va avanti con gli altri, senza FORCE e senza fermare la potatura.
      " ! #{name}: non l'ho buttato (#{e.message.lines.first.to_s.strip})"
    end

    def delete(path)
      path.delete
      " - #{path}: buttato"
    rescue SystemCallError => e
      " ! #{path}: non l'ho buttato (#{e.message})"
    end
  end
end
