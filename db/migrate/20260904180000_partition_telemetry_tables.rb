# frozen_string_literal: true

# CYRA-750 — le cinque tabelle che crescono col traffico dei clienti passano a FETTE MENSILI sul
# tempo d'arrivo, così la potatura notturna stacca una fetta intera invece di cancellare riga per
# riga. Il perché (chiave scelta, unicità spostata sulle fette, chiave primaria composta) sta in
# Ops::Partitions: qui c'è solo la trasformazione.
#
# PostgreSQL non converte una tabella esistente in tabella a fette: si costruisce la gemella divisa,
# si copiano i dati e si scambiano i nomi. Con le tabelle piene serve una finestra di manutenzione —
# la copia tiene un lock per tutta la sua durata.
#
# La descrizione delle tabelle è ricopiata qui dentro di proposito: una migration deve continuare a
# funzionare fra due anni anche se il catalogo dell'applicazione nel frattempo è cambiato.
class PartitionTelemetryTables < ActiveRecord::Migration[8.1]
  TABLES = [
    { name: "errors_events", key: "created_at",
      natural_key: %w[project_id event_id],
      natural_key_index: "index_errors_events_on_project_id_and_event_id",
      foreign_keys: [ { to: "errors_groups", column: "group_id" }, { to: "projects", column: "project_id" } ] },
    { name: "logs_entries", key: "created_at",
      natural_key: %w[project_id event_id],
      natural_key_index: "index_logs_entries_on_project_id_and_event_id",
      foreign_keys: [ { to: "projects", column: "project_id" } ] },
    { name: "metrics_samples", key: "created_at",
      natural_key: %w[project_id sample_id],
      natural_key_index: "index_metrics_samples_on_project_id_and_sample_id",
      foreign_keys: [ { to: "metrics_groups", column: "group_id" }, { to: "projects", column: "project_id" } ] },
    { name: "analytics_pageviews", key: "created_at",
      natural_key: %w[project_id event_id],
      natural_key_index: "index_analytics_pageviews_on_project_id_and_event_id",
      foreign_keys: [ { to: "projects", column: "project_id" } ] },
    # L'unicità dei campioni è già [host, istante] e contiene la chiave di divisione: resta sul padre.
    { name: "servers_samples", key: "recorded_at",
      natural_key: nil, natural_key_index: nil,
      foreign_keys: [ { to: "organizations", column: "organization_id" },
                      { to: "servers_hosts", column: "host_id" } ] }
  ].freeze

  MONTHS_AHEAD = 2

  def up
    # Un collegamento manuale non può più puntare a una tabella a fette: PostgreSQL pretende che la
    # colonna riferita sia unica, e su una tabella divisa l'unicità deve contenere il tempo. I
    # collegamenti rimasti orfani li pota Logs::PruneJob.
    remove_foreign_key :logs_links, :logs_entries if foreign_key_exists?(:logs_links, :logs_entries)

    TABLES.each { |table| partition!(table) }
  end

  def down
    TABLES.each { |table| unpartition!(table) }

    add_foreign_key :logs_links, :logs_entries, column: :log_entry_id, on_delete: :cascade
  end

  private

  # --- trasformazione in avanti -----------------------------------------------------------------

  def partition!(table)
    name = table[:name]
    parked = "#{name}_unpartitioned"
    keep = index_definitions(name).except(*[ table[:natural_key_index] ].compact)

    park_table!(name, parked)
    create_partitioned_twin!(table, parked)
    create_partitions!(table, source: parked)
    say_with_time("copia dei dati in #{name}") { execute("INSERT INTO #{q(name)} SELECT * FROM #{q(parked)}") }
    keep.each_value { |definition| execute(definition) }
    add_foreign_keys!(table)
    drop_table parked
  end

  # Sposta la tabella di partenza da parte E le toglie indici e chiave primaria: i nomi degli indici
  # sono unici nello schema, quindi finché li tiene lei la gemella non può prenderseli.
  def park_table!(name, parked)
    execute("ALTER TABLE #{q(name)} RENAME TO #{q(parked)}")
    primary_key_constraint(parked)&.then { |pk| execute("ALTER TABLE #{q(parked)} DROP CONSTRAINT #{q(pk)}") }
    index_names(parked).each { |index| execute("DROP INDEX IF EXISTS #{q(index)}") }
  end

  # `LIKE` copia colonne, tipi, valori di default e vincoli di controllo dalla tabella di partenza:
  # nessun elenco di colonne da tenere allineato a mano, e l'ordine resta identico (la copia dei dati
  # è un `SELECT *`).
  def create_partitioned_twin!(table, parked)
    execute(<<~SQL.squish)
      CREATE TABLE #{q(table[:name])} (
        LIKE #{q(parked)} INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING COMMENTS
      ) PARTITION BY RANGE (#{c(table[:key])})
    SQL
    execute(<<~SQL.squish)
      ALTER TABLE #{q(table[:name])}
        ADD CONSTRAINT #{q("#{table[:name]}_pkey")} PRIMARY KEY (#{c('id')}, #{c(table[:key])})
    SQL
  end

  # Le fette che coprono i dati già presenti, più il mese in corso e quelli in arrivo, più quella di
  # riserva. Senza le fette del passato la copia fallirebbe riga per riga; senza quella di riserva
  # una riga con un istante inatteso farebbe fallire una scrittura in produzione.
  def create_partitions!(table, source:)
    execute(<<~SQL.squish)
      CREATE TABLE #{q("#{table[:name]}_pdefault")} PARTITION OF #{q(table[:name])} DEFAULT
    SQL
    natural_key_index!(table, "#{table[:name]}_pdefault")

    months_for(table, source).each do |month|
      partition = "#{table[:name]}_p#{month.strftime('%Y_%m')}"
      execute(<<~SQL.squish)
        CREATE TABLE #{q(partition)} PARTITION OF #{q(table[:name])}
          FOR VALUES FROM ('#{month.strftime('%Y-%m-%d %H:%M:%S')}')
                       TO ('#{month.next_month.strftime('%Y-%m-%d %H:%M:%S')}')
      SQL
      natural_key_index!(table, partition)
    end
  end

  # Gli estremi si leggono come TESTO: il tipo che tornerebbe altrimenti dipende dalla conversione
  # dell'adapter, e un fuso applicato per sbaglio sposterebbe di un mese la prima fetta.
  def months_for(table, source)
    span = select_one(<<~SQL.squish)
      SELECT to_char(MIN(#{c(table[:key])}), 'YYYY-MM-DD') AS lo,
             to_char(MAX(#{c(table[:key])}), 'YYYY-MM-DD') AS hi
      FROM #{q(source)}
    SQL
    now = Time.now.utc.beginning_of_month
    first = span["lo"] ? Time.utc(*span["lo"].split("-").first(2).map(&:to_i)) : now
    last = [ span["hi"] ? Time.utc(*span["hi"].split("-").first(2).map(&:to_i)) : now, now + MONTHS_AHEAD.months ].max

    months = []
    cursor = first
    while cursor <= last
      months << cursor
      cursor += 1.month
    end
    months
  end

  # L'indice unico della chiave naturale vive sulla singola fetta (vedi Ops::Partitions): sul padre
  # PostgreSQL lo accetterebbe solo col tempo dentro, e con quello dentro non sarebbe più un vincolo
  # di idempotenza.
  def natural_key_index!(table, partition)
    return if table[:natural_key].blank?

    columns = table[:natural_key].map { |column| c(column) }.join(", ")
    execute("CREATE UNIQUE INDEX #{q("#{partition}_natkey")} ON #{q(partition)} (#{columns})")
  end

  def add_foreign_keys!(table)
    table[:foreign_keys].each do |fk|
      add_foreign_key table[:name], fk[:to], column: fk[:column], on_delete: :cascade
    end
  end

  # --- ritorno indietro --------------------------------------------------------------------------

  # Rifà la tabella piatta e ci rimette l'unicità globale della chiave naturale. Se nel frattempo
  # sono entrati doppioni che solo le fette tenevano separati, l'indice unico fallisce QUI, in
  # chiaro, invece di lasciare in giro una tabella che si crede unica e non lo è.
  def unpartition!(table)
    name = table[:name]
    parked = "#{name}_partitioned"
    keep = index_definitions(name)

    execute("ALTER TABLE #{q(name)} RENAME TO #{q(parked)}")
    primary_key_constraint(parked)&.then { |pk| execute("ALTER TABLE #{q(parked)} DROP CONSTRAINT #{q(pk)}") }
    index_names(parked).each { |index| execute("DROP INDEX IF EXISTS #{q(index)}") }

    execute("CREATE TABLE #{q(name)} (LIKE #{q(parked)} INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING COMMENTS)")
    execute("ALTER TABLE #{q(name)} ADD CONSTRAINT #{q("#{name}_pkey")} PRIMARY KEY (#{c('id')})")
    say_with_time("copia dei dati in #{name}") { execute("INSERT INTO #{q(name)} SELECT * FROM #{q(parked)}") }
    keep.each_value { |definition| execute(definition) }
    if table[:natural_key_index]
      columns = table[:natural_key].map { |column| c(column) }.join(", ")
      execute("CREATE UNIQUE INDEX #{q(table[:natural_key_index])} ON #{q(name)} (#{columns})")
    end
    add_foreign_keys!(table)
    execute("DROP TABLE #{q(parked)} CASCADE")
  end

  # --- lettura del catalogo ----------------------------------------------------------------------

  # Le definizioni degli indici DELLA TABELLA PADRE, per nome. Si leggono prima dello spostamento,
  # quindi nominano già la tabella definitiva: si rieseguono così come sono. Gli indici delle fette
  # non compaiono (`pg_indexes` è per tabella).
  def index_definitions(table)
    pkey = primary_key_constraint(table).to_s
    select_all(<<~SQL.squish).to_h { |row| [ row["indexname"], row["indexdef"] ] }
      SELECT indexname, indexdef FROM pg_indexes
      WHERE schemaname = 'public' AND tablename = #{quote(table)}
        AND indexname <> #{quote(pkey)}
    SQL
  end

  def index_names(table)
    select_all(<<~SQL.squish).pluck("indexname")
      SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = #{quote(table)}
    SQL
  end

  def primary_key_constraint(table)
    select_value(<<~SQL.squish)
      SELECT con.conname FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
      WHERE rel.relname = #{quote(table)} AND con.contype = 'p'
    SQL
  end

  def q(identifier) = connection.quote_table_name(identifier)
  def c(column) = connection.quote_column_name(column)
  def quote(value) = connection.quote(value)
  def select_all(sql) = connection.select_all(sql)
  def select_one(sql) = connection.select_one(sql)
  def select_value(sql) = connection.select_value(sql)
end
