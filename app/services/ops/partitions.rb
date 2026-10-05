# frozen_string_literal: true

module Ops
  # Le cinque tabelle di telemetria sono divise a FETTE MENSILI sul tempo d'arrivo (CYRA-750).
  #
  # PERCHÉ. La potatura notturna cancellava riga per riga. Su queste cinque tabelle — le uniche che
  # crescono col traffico dei clienti e non con l'uso del prodotto — una `DELETE` non restituisce
  # spazio: lascia tuple morte che autovacuum deve ripassare, e il costo di quella pulizia sale col
  # numero di righe cancellate ogni notte. Una fetta scaduta INTERA invece si stacca con un `DROP
  # TABLE`: costante, immediata, e lo spazio torna al filesystem.
  #
  # LA CHIAVE È IL TEMPO D'ARRIVO, non quello dichiarato dal client (`occurred_at`). Due ragioni:
  # la conservazione si misura già su `created_at` (`recorded_at` per i campioni dei server), quindi
  # la semantica non cambia di una virgola; e un client con l'orologio sbagliato — o malintenzionato —
  # potrebbe altrimenti scegliere in quale fetta finire, cioè per quanto tempo restare.
  #
  # UNICITÀ. PostgreSQL accetta un indice unico su una tabella a fette solo se contiene la chiave di
  # divisione: `(project_id, event_id)` globale è impossibile. Aggiungere `created_at` all'indice
  # avrebbe spento l'idempotenza dell'ingest (una consegna ripetuta arriva con un istante diverso e
  # non sarebbe più un duplicato), quindi l'indice unico vive SU OGNI FETTA (vedi
  # Ops::Partitions::Ensure) e gli `insert_all` degli ingest usano `ON CONFLICT DO NOTHING` SENZA
  # bersaglio, che rispetta ogni vincolo unico della fetta in cui la riga sta entrando. Resta fuori
  # un solo caso: la stessa consegna ripetuta a cavallo del cambio di mese. Il buco è quello, ed è
  # scritto qui perché nessuno lo scopra da un conteggio sbagliato.
  #
  # PRIMARY KEY. Sulla tabella padre è `(id, <chiave>)` — PostgreSQL non ne accetta altre — ma i
  # modelli dichiarano `self.primary_key = "id"`: l'applicazione continua a vedere un id solo, e
  # `find(id)` resta un accesso per indice perché `id` è la colonna guida della chiave composta.
  module Partitions
    # Una tabella a fette. `key` è la colonna di divisione (e quella su cui si misura la
    # conservazione); `natural_key` sono le colonne che devono restare uniche DENTRO una fetta —
    # nil quando l'unicità sta già sul padre perché contiene la chiave (campioni dei server).
    Table = Data.define(:name, :key, :natural_key)

    TABLES = [
      Table.new(name: "errors_events", key: "created_at", natural_key: %w[project_id event_id]),
      Table.new(name: "logs_entries", key: "created_at", natural_key: %w[project_id event_id]),
      Table.new(name: "metrics_samples", key: "created_at", natural_key: %w[project_id sample_id]),
      Table.new(name: "analytics_pageviews", key: "created_at", natural_key: %w[project_id event_id]),
      Table.new(name: "servers_samples", key: "recorded_at", natural_key: nil)
    ].freeze

    # Quante fette FUTURE tenere già pronte. Una fetta che manca non fa fallire la scrittura (c'è
    # quella di riserva), ma la riga finita lì dentro non è più staccabile in un istante: due mesi
    # di margine reggono un giro ricorrente fermo per settimane senza che nessuno se ne accorga.
    MONTHS_AHEAD = 2

    # Suffisso della fetta di riserva: prende tutto ciò che non rientra in nessuna fetta dichiarata.
    # Non è un ripiego elegante, è la ragione per cui un giro di manutenzione mancato non diventa un
    # errore di scrittura in faccia al cliente che manda i dati.
    DEFAULT_SUFFIX = "pdefault"

    module_function

    def table(name) = TABLES.find { |t| t.name == name } || raise(KeyError, "tabella non a fette: #{name}")

    def table_names = TABLES.map(&:name)

    # Nome della fetta che contiene `time`. Il calcolo è in UTC perché le colonne sono
    # `timestamp without time zone` e ActiveRecord ci scrive UTC: leggerle nel fuso locale
    # sposterebbe di ore il confine fra due fette.
    def partition_name(table_name, time)
      "#{table_name}_p#{time.utc.strftime('%Y_%m')}"
    end

    def default_partition_name(table_name) = "#{table_name}_#{DEFAULT_SUFFIX}"

    # Estremi [da, a) della fetta mensile che contiene `time`.
    def bounds_for(time)
      from = time.utc.beginning_of_month
      [ from, from.next_month ]
    end

    # Le fette dichiarate hanno tutte questa forma: è anche il filtro che tiene la fetta di riserva
    # fuori dalla potatura (non ha un mese, quindi non scade mai).
    def monthly_pattern(table_name) = /\A#{Regexp.escape(table_name)}_p(\d{4})_(\d{2})\z/

    # Le fette non compaiono in `db/schema.rb`: il dumper di Rails le vedrebbe come tabelle a sé e le
    # riscriverebbe con `INHERITS`, che è l'ereditarietà vecchia e NON una fetta. Qui c'è la regola
    # che l'inizializzatore usa per ignorarle (spec/config/partitions_spec.rb lega le due cose).
    def dumper_ignore_pattern
      /\A(?:#{table_names.map { |n| Regexp.escape(n) }.join('|')})_p(?:\d{4}_\d{2}|default)\z/
    end
  end
end
