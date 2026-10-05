# frozen_string_literal: true

module Logs
  module Ingest
    # Normalizza un log raw nel sottoinsieme persistito. Scrub PII degli `attributes` (denylist
    # ricorsiva) e del `message` come difesa-in-profondità (la gemma scrubba già a monte). NON tocca
    # il DB. Mappa i nomi del payload gemma (`attributes`/`logger`) sulle colonne `data`/`logger_name`
    # (nomi AR-safe).
    class Normalize < ApplicationService
      include ::Ingest::PayloadCleaning
      include ::Ingest::EpochTime
      include ::Ingest::PiiScrubbing

      Normalized = Data.define(
        :event_id, :occurred_at, :level, :message, :data, :logger_name, :trace_id, :trace_id_extracted,
        :environment, :release, :sdk_name, :sdk_version
      )

      LEVELS = %w[debug info warning error fatal].freeze

      # Formato UUID canonico (8-4-4-4-12), case-insensitive: sia il request_id di Rails
      # (ActionDispatch::RequestId) sia il job_id di ActiveJob nascono da SecureRandom.uuid.
      TRACE_UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

      # Prefisso TaggedLogging di Rails: il request_id come PRIMO tag a inizio riga
      # (config.log_tags = [:request_id]), es. "[e146fed6-…] ActiveRecord::RecordNotFound".
      # Ancorato a inizio RIGA (`^`), NON a inizio stringa (CYRA-559): il messaggio d'eccezione che
      # Rails emette davvero comincia con la riga vuota di DebugExceptions, quindi il tag arriva dopo
      # due spazi e un a capo, e con `\A` non combaciava MAI — il codice era scritto nel messaggio
      # (una volta per riga taggata) e la pagina rispondeva che non c'era. Gli spazi iniziali sono
      # tollerati per le righe rientrate del backtrace. Il vincolo posizionale resta: un `[uuid]`
      # citato a metà frase non è il prefisso di quella riga e unirebbe richieste diverse.
      TRACE_FROM_TAG = /^[[:blank:]]*\[(#{TRACE_UUID})\]/

      # ActiveJob: "Performing MyJob (Job ID: <uuid>) from …" — il job_id identifica l'unità di lavoro.
      TRACE_FROM_JOB_ID = /Job ID:\s*(#{TRACE_UUID})/i

      # Pre-filtro SQL dei candidati, usato SOLO da Logs::BackfillTraceIdsJob per non istanziare in
      # Ruby l'intera tabella più grande del prodotto a ogni giro. NON è autoritativo: decidono i due
      # pattern qui sopra. Deve restare più LARGO di entrambi — cerca i soli marcatori letterali,
      # senza l'UUID — altrimenti il backfill scarta log che l'ingest riconosce e le due strade
      # divergono in silenzio. Chi aggiunge un pattern qui sopra allarga anche questo.
      TRACE_CANDIDATE_SQL = "message LIKE '%[%' OR LOWER(message) LIKE '%job id:%'"

      # La denylist PII è UNA (::Ingest::PiiScrubbing::SENSITIVE_KEY, incluso qui sopra). Prima era
      # copiata: la copia era già stata più corta di quella del canale errori e lasciava passare
      # email/telefono/nascita (CYRA-214). Con un solo elenco la divergenza non è più possibile.
      # Denylist canonica: closeyourit-docs/decisions/2026-07-09-pii-scrub-parity.md.

      # Cap sul message persistito (byte): un log verboso (es. un body da 3 MB) non deve gonfiare la
      # tabella piu' grande ne saturare i broadcast realtime.
      MESSAGE_MAX_BYTES = 16_000
      # Cap sulla dimensione serializzata degli `attributes` persistiti (jsonb `data`), CYRA-62: senza,
      # un client buggato/compromesso POSTa un batch (fino a LOGS_MAX_BATCH item) con attributes da MB
      # ciascuno → ~GB nella tabella piu' grande + broadcast realtime gonfiati. Misurato DOPO lo scrub
      # (dimensione realmente persistita): un valore sensibile enorme viene ridotto a [FILTERED] e non
      # triggera il cap. È un limite difensivo anti-abuso, non un limite di prodotto (16 KB di JSON
      # strutturato = centinaia di campi legittimi).
      DATA_MAX_BYTES = 16_000

      # Pre-check leggero (CYRA-58): un item ha un message persistibile? Applica SOLO la normalizzazione
      # del message (strip dei null byte, come #call) — nessun deep_clean dell'intero payload né scrub
      # ricorsivo degli `attributes`. È il filtro usato dal controller nel thread web (fino a 1000 item
      # per batch): la Normalize completa, costosa su attributes annidati/grandi, resta nel job. Coerente
      # col filtro di persistenza (#call scarta se `message.blank?`) — il caso limite del message di soli
      # null byte incluso: un item accettato qui è esattamente uno persistito dal job.
      def self.message_present?(item)
        item.is_a?(Hash) && item["message"].to_s.delete(NULL_BYTE).present?
      end

      # Riconosce l'identificativo di richiesta nel TESTO di un log quando il campo strutturato manca
      # (CYRA-345). SOLO due pattern POSIZIONALI in formato UUID — prefisso tag a inizio riga, label
      # "Job ID:" — che è il default di Rails (ActionDispatch::RequestId) e ActiveJob e copre "quasi tutti
      # i log presenti", senza catturare un UUID qualsiasi citato nel messaggio (es. l'id di un record):
      # meglio un miss che un falso positivo che unisce richieste diverse. Un request_id PERSONALIZZATO
      # non-UUID (raro, da X-Request-Id) NON viene dedotto: resta affidato al campo trace_id strutturato,
      # canale primario sempre valido — allargare il prefisso a [token] catturerebbe qualsiasi tag
      # TaggedLogging ([CLI], [nome]) reintroducendo il falso positivo che il ticket vieta. Fonte di verità
      # UNICA, condivisa da #call (ingest) e da Logs::BackfillTraceIdsJob (recupero sui log in retention).
      def self.trace_id_from_message(message)
        text = message.to_s
        match = text.match(TRACE_FROM_TAG) || text.match(TRACE_FROM_JOB_ID)
        match && match[1]
      end

      def initialize(payload:)
        # Guard non-Hash + strip null-byte ricorsivo: Postgres li rifiuta in text/jsonb e UN log
        # avvelenato fa fallire l'insert_all dell'INTERO batch (retry x3 -> drop di fino a 1000 log sani).
        @payload = deep_clean(payload.is_a?(Hash) ? payload : {})
      end

      def call
        message = scrubbed_message
        structured_trace = @payload["trace_id"].presence
        # Fallback: se il client non manda il campo strutturato, prova a riconoscere l'identificativo
        # nel testo del messaggio. Marca la provenienza (trace_id_extracted) così la UI segnala che il
        # collegamento è dedotto dal testo, non certificato dal client (CYRA-345).
        extracted_trace = structured_trace ? nil : self.class.trace_id_from_message(message)
        Normalized.new(
          event_id: @payload["event_id"].to_s.presence || SecureRandom.uuid,
          occurred_at: parse_time(@payload["timestamp"]),
          level: level,
          message: message,
          data: scrubbed_data,
          logger_name: @payload["logger"].presence,
          trace_id: structured_trace || extracted_trace,
          trace_id_extracted: extracted_trace.present?,
          environment: @payload["environment"].presence,
          release: @payload["release"].presence,
          sdk_name: sdk_name,
          sdk_version: sdk_version
        )
      end

      private

      # CYRA-735 — il messaggio è testo libero e ci finisce dentro di tutto: un indirizzo con il token
      # nella query, una riga di configurazione con la password. Il backend è l'autorità PII su tutti i
      # canali, come già faceva sul testo dei breadcrumb degli errori: si redige il valore delle sole
      # assegnazioni sensibili e la frase resta leggibile. Lo scrub viene PRIMA del taglio ai byte,
      # perché sostituire un valore col segnaposto può allungare la stringa: tagliare dopo tiene buono
      # il tetto. Non può svuotare un messaggio pieno, quindi il pre-filtro .message_present? del
      # controller resta coerente con ciò che il job persiste.
      def scrubbed_message
        scrub_message(@payload["message"].to_s).truncate_bytes(MESSAGE_MAX_BYTES)
      end

      # Identità del client dal filo (Sentry `sdk: {name, version}`) — alimenta la card Monitoring tools.
      def sdk_name
        sdk = @payload["sdk"]
        sdk["name"].to_s.presence if sdk.is_a?(Hash)
      end

      def sdk_version
        sdk = @payload["sdk"]
        sdk["version"].to_s.presence if sdk.is_a?(Hash)
      end

      def level
        lvl = @payload["level"].to_s
        LEVELS.include?(lvl) ? lvl : "info"
      end

      def scrubbed_data
        attrs = @payload["attributes"]
        attrs.is_a?(Hash) ? cap_data(scrub_hash(attrs)) : {}
      end

      # Cap sulla dimensione serializzata degli attributes (CYRA-62). Non si può troncare un JSON a
      # metà senza romperlo → l'oversized viene rimpiazzato da un marker minuscolo che preserva il
      # segnale (dimensione originale) senza gonfiare storage/memory. Confine: `<= DATA_MAX_BYTES` passa.
      def cap_data(data)
        bytes = data.to_json.bytesize
        return data if bytes <= DATA_MAX_BYTES

        { "_truncated" => true, "_original_bytes" => bytes }
      end
    end
  end
end
