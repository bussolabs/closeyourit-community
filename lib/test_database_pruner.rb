# frozen_string_literal: true

require "pathname"

# CYRA-587 — Ogni lavorazione ha il proprio spazio dati di prova (TEST_SLOT in config/database.yml),
# ma nessuno lo butta quando la lavorazione finisce: ne erano rimasti 42, tutti allo schema del giorno
# in cui sono nati. Questa classe decide QUALI si possono buttare. Non butta niente da sé: guarda una
# fotografia (i database che esistono, chi è collegato, i file di prova, le cartelle di lavoro aperte)
# e restituisce il piano — così la parte che decide si può provare senza un database vero davanti.
#
# Il rischio da tenere a mente è tutto da una parte: far sparire lo spazio dati a una suite che sta
# girando è ESATTAMENTE il guasto che il ticket voleva togliere di mezzo, e sarebbe pure peggio,
# perché arriverebbe da un comando che dice di fare pulizia. Quindi qui la domanda non è «cosa posso
# buttare» ma «cosa non posso toccare», e le risposte sono quattro, indipendenti fra loro:
#
#   1. qualcuno ci è collegato adesso            → la suite sta girando
#   2. è un archivio di parallel_tests           → lo rifà solo un `parallel:prepare` da capo
#   3. la cartella di lavoro esiste ancora       → lavorazione aperta, magari in pausa fra due comandi
#   4. i suoi file sono stati toccati da poco    → è l'unica età che si riesce a misurare
#
# Basta una sola a salvare, e ognuna può soltanto tenere di più: sbagliare tenendo costa un database
# di troppo, sbagliare buttando costa una suite morta a metà e mezz'ora a capire perché.
#
# Sulla quarta: PostgreSQL non registra da nessuna parte quando un database è stato creato o usato
# l'ultima volta — `pg_stat_file` sulla sua cartella vorrebbe privilegi che qui non ci sono. I file
# SQLite di cache e cable invece hanno una data di modifica, e siccome nascono e vengono toccati
# insieme ai database della stessa lavorazione, la loro età vale per tutta la famiglia.
class TestDatabasePruner
  # Nessuna macchina fa girare più di sedici processi rspec insieme: oltre questo numero il suffisso
  # non viene da parallel_tests ma da qualcuno che, prima che TEST_SLOT esistesse, si isolava
  # scrivendo a mano un numero di ticket in TEST_ENV_NUMBER (`closeyourit_test153`, `_test220`).
  # Quelli sono spazi abbandonati a tutti gli effetti.
  PARALLEL_PROCESS_CEILING = 16

  # Due ore: una lavorazione può stare ferma parecchio fra due lanci della suite, e il costo di
  # tenersi un database in più per un giro di potatura è zero.
  IDLE_GRACE = 2 * 60 * 60

  REASONS = {
    canonical: "è l'archivio di chi lavora senza spazio dati dichiarato",
    parallel: "è un archivio dei processi di prova in parallelo",
    busy: "c'è una lavorazione collegata adesso",
    live: "la lavorazione che lo usa è ancora aperta",
    fresh: "è stato usato da poco"
  }.freeze

  Kept = Data.define(:name, :reason)

  Plan = Data.define(:databases, :files, :kept) do
    def empty? = databases.empty? && files.empty?

    def message
      return "Nessuno spazio dati di prova da buttare.#{kept_summary}" if empty?

      lines = [ "Spazi dati di prova da buttare (#{databases.size + files.size}):" ]
      lines += (databases + files.map(&:to_s)).map { |name| " - #{name}" }
      lines.join("\n") + kept_summary
    end

    # I tenuti si elencano col loro motivo, sempre: una potatura che dice solo quanti ne ha buttati
    # non lascia modo di accorgersi che sta risparmiando (o peggio, buttando) la cosa sbagliata.
    def kept_summary
      return "" if kept.empty?

      ([ "", "Tenuti (#{kept.size}):" ] + kept.map { |item| " - #{item.name} — #{item.reason}" }).join("\n")
    end
  end

  def self.plan(...) = new(...).plan

  def initialize(databases:, canonical_databases:, canonical_files:, busy_databases: [], files: [],
                 live_names: [], now: Time.now)
    @databases = databases.map(&:to_s)
    @busy_databases = busy_databases.map(&:to_s)
    @files = files.map { |path| Pathname.new(path) }
    @canonical_databases = canonical_databases.map(&:to_s)
    @canonical_files = canonical_files.map { |path| Pathname.new(path) }
    @live_names = live_names.map(&:to_s)
    @now = now
  end

  def plan
    kept = []
    prunable_databases = []
    prunable_files = []

    database_candidates.each do |name, suffix|
      reason = keep_reason(suffix, busy: @busy_databases.include?(name))
      reason ? kept << Kept.new(name: name, reason: REASONS.fetch(reason)) : prunable_databases << name
    end

    file_candidates.each do |path, suffix|
      reason = keep_reason(suffix, fresh: fresh?(path))
      reason ? kept << Kept.new(name: path.to_s, reason: REASONS.fetch(reason)) : prunable_files << path
    end

    Plan.new(databases: prunable_databases.sort, files: prunable_files.sort, kept: kept.sort_by(&:name))
  end

  private

  attr_reader :now

  # Un database è "nostro" solo se sta sotto uno dei nomi che la configurazione di test userebbe con
  # le variabili vuote. Tutto il resto — sviluppo, altri progetti, i database di sistema — non viene
  # nemmeno considerato: non compare fra i tenuti perché non è mai stato in discussione.
  def database_candidates
    @database_candidates ||= @databases.filter_map do |name|
      prefix = @canonical_databases.select { |candidate| name.start_with?(candidate) }.max_by(&:length)
      next if prefix.nil?

      [ name, name.delete_prefix(prefix) ]
    end
  end

  # I file di cache e cable, più le code di scrittura che SQLite si porta dietro (`-wal`, `-shm`):
  # lasciarle indietro vorrebbe dire pulire a metà.
  def file_candidates
    @file_candidates ||= begin
      patterns = @canonical_files.map do |path|
        [ path.dirname, /\A#{Regexp.escape(path.basename.to_s.sub(/\.sqlite3\z/, ""))}(.*)\.sqlite3(-wal|-shm)?\z/ ]
      end

      @files.filter_map do |path|
        _, pattern = patterns.find { |dir, regexp| path.dirname == dir && path.basename.to_s.match?(regexp) }
        next if pattern.nil?

        [ path, path.basename.to_s[pattern, 1] ]
      end
    end
  end

  def keep_reason(suffix, busy: false, fresh: false)
    return :canonical if suffix.blank?
    return :busy if busy
    return :fresh if fresh
    return :parallel if parallel_process?(suffix)
    return :live if live?(suffix)

    nil
  end

  def parallel_process?(suffix)
    suffix.match?(/\A\d+\z/) && suffix.to_i.between?(1, PARALLEL_PROCESS_CEILING)
  end

  # Confronto per somiglianza, non per uguaglianza: lo spazio dati nasce dal nome della cartella di
  # lavoro ma non lo ricopia (`CYRA-591-scheda-lavorazione` → `_cyra591`), e i processi paralleli gli
  # attaccano in fondo la propria cifra (`_cyra5912`). Chi somiglia si tiene.
  def live?(suffix)
    variants(normalize(suffix)).any? do |variant|
      live_suffixes.any? { |live| live.start_with?(variant) || variant.start_with?(live) }
    end
  end

  def live_suffixes
    @live_suffixes ||= begin
      from_names = @live_names.map { |name| normalize(name) }
      from_busy = database_candidates.select { |name, _| @busy_databases.include?(name) }
      from_fresh = file_candidates.select { |path, _| fresh?(path) }

      (from_names + (from_busy + from_fresh).map { |_, suffix| normalize(suffix) }).reject(&:empty?).uniq
    end
  end

  # Le varianti tolgono di mezzo la cifra che parallel_tests attacca in fondo allo spazio dati
  # (`_cyra5912` è il secondo processo di `_cyra591`). Devono però finire tutte con una cifra: senza
  # quel vincolo `cyra79` produrrebbe anche `cyra`, che somiglia a qualunque cartella di questo
  # prodotto — sulla macchina vera bastava una cartella chiamata `cyra-prod` per salvare uno spazio
  # dati abbandonato da mesi. Somigliarsi vuol dire arrivare fino al numero della lavorazione.
  def variants(suffix)
    [ suffix, suffix.sub(/\d\z/, ""), suffix.sub(/\d{1,2}\z/, "") ]
      .uniq
      .select { |variant| variant.match?(/\d\z/) || variant == suffix }
      .reject(&:empty?)
  end

  def normalize(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, "")
  end

  def fresh?(path)
    path.exist? && (now - path.mtime) < IDLE_GRACE
  end
end
