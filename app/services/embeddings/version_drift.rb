# frozen_string_literal: true

module Embeddings
  # Rileva ciò che è INVISIBILE alla ricerca semantica su ciascuna delle tre tabelle embeddate. Due
  # cause, entrambe silenziose per costruzione (nessun errore, risultati parziali spacciati per
  # completi):
  #   * stale  — la riga HA un vettore ma NON la versione CORRENTE (Ai::Constants::EMBEDDING_VERSION):
  #              lo scope current_embedding, anteposto a OGNI nearest_neighbors (ricerca, duplicati,
  #              correlate, RAG), la filtra via. Vedi CYRA-206.
  #   * missing — la riga non è MAI stata indicizzata (embedding NULL): dopo un guasto del servizio
  #              embedding resta fuori dalla ricerca per sempre, ma nessun conteggio la vedeva e il
  #              pannello restava verde. Vedi CYRA-232.
  #
  # Sorgente UNICA dei conteggi per il monitor periodico (Embeddings::CheckVersionDriftJob) e per la
  # dashboard god (Valhalla::DashboardSignals). Rimedi: stale → ri-embed/timbratura dedicati
  # (Ticketing::BackfillEmbeddingsJob & co. ricalcolano; Embeddings::BackfillVersionJob timbra la
  # corrente sul vettore già presente quando la versione è solo ASSENTE); missing → gli stessi backfill,
  # ora anche in recurring.yml, riparano da soli la finestra di guasto.
  class VersionDrift
    # key stabile (non il nome di classe) → l'i18n della dashboard e il log restano disaccoppiati dal
    # namespace Ruby.
    MODELS = {
      tickets: Ticketing::Ticket,
      error_groups: Errors::Group,
      knowledge_pages: Knowledge::Page,
      # CYRA-167: anche le idee sono cercabili per significato e usate per suggerire i doppioni →
      # un buco nel loro indice è invisibile esattamente come gli altri e va contato qui.
      ideas: Ideas::Idea,
      # CYRA-914 P8: helpdesk requests are grouped by meaning too.
      helpdesk_requests: Helpdesk::Request
    }.freeze

    # Grazia sui vettori mai calcolati: subito dopo la create la riga resta con embedding NULL finché il
    # job async (coda :ingest) non gira — pochi minuti in salute. Solo oltre questa finestra il NULL
    # smette di essere "in coda" e diventa "rimasto fuori dalla ricerca" (buco da guasto). Sotto soglia
    # NON entra in missing, così i riquadri non lampeggiano rossi per la normale attesa post-creazione.
    MISSING_GRACE = 1.hour

    # Conteggi di una singola tabella, tutti dallo stesso snapshot (una query: sotto embed/delete
    # concorrenti COUNT separati darebbero valori incoerenti → stale negativo). current ⊆ embedded, quindi
    # stale = embedded - current ≥ 0. missing è già filtrato per età nella query (solo oltre la grazia).
    # Entrambe le categorie sono invisibili alla ricerca → entrambe fanno scattare drift?.
    Table = Data.define(:key, :embedded, :current, :missing) do
      def stale = embedded - current
      def drift? = stale.positive? || missing.positive?
    end

    Report = Data.define(:tables) do
      def any_drift? = tables.any?(&:drift?)
      def total_stale = tables.sum(&:stale)
      def total_missing = tables.sum(&:missing)
      def drifted = tables.select(&:drift?)
    end

    def self.call(now: Time.current) = new(now: now).call

    # `now` iniettabile per i test; @cutoff fisso all'istanziazione così le tre tabelle usano lo stesso
    # confine di grazia (nessuna deriva tra le query).
    def initialize(now: Time.current)
      @cutoff = now - MISSING_GRACE
    end

    def call
      Report.new(tables: MODELS.map { |key, model| table_for(key, model) })
    end

    private

    # UNA query per tabella: tre COUNT condizionali via FILTER dallo stesso snapshot (no valori
    # incoerenti) con una sola scansione. current richiede embedding IS NOT NULL oltre alla versione:
    # tiene l'invariante current ⊆ embedded (una versione timbrata su una riga senza vettore darebbe
    # stale negativo, nascondendo il drift). missing esclude la finestra di grazia (created_at < cutoff)
    # così l'attesa normale post-creazione non conta.
    def table_for(key, model)
      # Rows of organizations with their own embedding model carry their own version (CYRA-914).
      versions = Ai::Configuration.embedding_versions
      embedded, current, missing = model.pick(
        Arel.sql("COUNT(*) FILTER (WHERE embedding IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE embedding IS NOT NULL AND embedding_version IN (?))", versions),
        Arel.sql("COUNT(*) FILTER (WHERE embedding IS NULL AND created_at < ?)", @cutoff)
      )
      Table.new(key: key, embedded: embedded.to_i, current: current.to_i, missing: missing.to_i)
    end
  end
end
