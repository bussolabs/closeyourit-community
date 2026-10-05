# frozen_string_literal: true

module Usage
  # CYRA-700 — CloseYourIt che dice quali sue parti girano davvero.
  #
  # Il canale d'ingresso esiste da CYSK-29, ma nessuno gli parlava: 359 funzionalità e zero eventi,
  # quindi ogni domanda su cosa serve e cosa no restava un'opinione. Qui parla l'applicazione stessa,
  # con la STESSA forma di un SDK esterno — `Controller#action` sotto il kind `route`, mai l'URL — e
  # senza passare da HTTP: il job d'ingest è già il proprietario della scrittura, chiamarlo per rete
  # significherebbe soltanto aggiungere un token e un giro di rete fra due oggetti dello stesso
  # processo.
  #
  # Buffer per PROCESSO, come flusha un SDK: una pagina aperta non è una scrittura: si accumula in
  # memoria (chiave [kind, simbolo]) e si accoda un solo flush ogni WINDOW. Multi-processo non è un
  # problema — l'ingest fonde con GREATEST(last_seen_at) e l'ordine di arrivo non conta.
  #
  # SPENTO finché `CLOSEYOURIT_SELF_PROJECT_ID` non nomina un progetto: senza, `record` non tiene
  # nemmeno il simbolo in memoria. Un prodotto multi-tenant non deve indovinare di chi è il traffico
  # che sta misurando.
  #
  # Nel simbolo non c'è niente di personale, per costruzione: non l'utente, non il path, non i
  # parametri, non l'IP. Il nome della classe e quello dell'azione, e basta — o, per il kind
  # `feature_view` (CYRA-733), la chiave della funzione aperta, che di identificativi non ne ha.
  class SelfRecorder
    WINDOW = 5.minutes
    # Un processo che vede troppi simboli distinti sta guardando qualcosa che non è una rotta: il
    # tetto tiene il buffer limitato senza mai far fallire la richiesta che lo sta riempiendo.
    MAX_SYMBOLS = 2000

    class << self
      def project_id = ENV["CLOSEYOURIT_SELF_PROJECT_ID"].presence

      def enabled? = project_id.present?

      # `kind` è quello del contratto CYSK-29: `route` per la pagina tecnica, `feature_view` per la
      # funzione di prodotto (CYRA-733). Lo stesso testo sotto due kind resta due voci: sono due
      # domande diverse, e sommarle direbbe il doppio delle aperture su entrambe.
      def record(symbol, kind: "route", now: Time.current)
        return unless enabled?
        return unless ::Usage::Symbol::KINDS.include?(kind.to_s)
        return unless symbol.to_s.match?(::Usage::Symbol::SYMBOL_FORMAT)

        slot = [ kind.to_s, symbol.to_s ]
        mutex.synchronize do
          entry = buffer[slot]
          return if entry.nil? && buffer.size >= MAX_SYMBOLS

          buffer[slot] = { count: (entry&.fetch(:count) || 0) + 1, last_seen_at: now }
        end
      end

      # Accoda al più UN flush per finestra e svuota. Il buffer si svuota DENTRO il lock e il job si
      # accoda fuori: accodare tenendo il lock bloccherebbe ogni altra richiesta del processo per il
      # tempo di una scrittura sulla coda.
      def flush_if_due!(now: Time.current)
        return unless enabled?

        payload = nil
        mutex.synchronize do
          return if now - @flushed_at < WINDOW
          return if buffer.empty?

          payload = buffer.map do |(kind, symbol), entry|
            { "kind" => kind, "symbol" => symbol, "count" => entry[:count],
              "last_seen_at" => entry[:last_seen_at].iso8601 }
          end
          buffer.clear
          @flushed_at = now
        end
        return if payload.nil?

        ::Usage::IngestJob.perform_later(
          project_id: project_id, environment: App::Version.environment,
          sdk: { "name" => App::Version.app, "version" => release.to_s },
          release: release, truncated: false, symbols: payload
        )
      end

      # Solo per le prove: il buffer è stato in un processo, non un dato.
      def reset!
        mutex.synchronize do
          buffer.clear
          @flushed_at = Time.current
        end
      end

      def buffered = buffer.dup

      private

      # Fuori da un'immagine costruita dalla CI il tag non c'è: meglio nessuna release che la
      # stringa «unknown» scritta su ogni riga come se fosse il nome di una versione.
      def release = App::Version.tag == "unknown" ? nil : App::Version.tag

      def buffer = (@buffer ||= {})
      def mutex = (@mutex ||= Mutex.new)
    end

    @flushed_at = Time.current
  end
end
