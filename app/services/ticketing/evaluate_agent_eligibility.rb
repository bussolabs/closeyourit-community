# frozen_string_literal: true

require "base64"

module Ticketing
  # Gate di sicurezza del sistema agenti (CYRA-184): decide se un ticket può essere lavorato da un
  # agente AI autonomo, leggendo corpo E allegati (immagini, PDF, testo). Stesso pattern di
  # Errors::TriageWithAi e Datasets::Ai::Predict: server AI con `response_schema` via Ai::Structured.
  #
  # UN MOTORE SOLO (CYRA-594). Fino a qui erano due: il testo andava sul gateway Proxanything, che non
  # aveva tetti di quota ma non leggeva le immagini, e le immagini andavano al fornitore generativo,
  # che le legge ma a quota stretta. Il gateway si appoggiava a un pod affittato a ore: finito il
  # credito si è spento, e con lui tutte le funzioni che ci passavano. Il verdetto ora esce sempre
  # dal server AI di casa (CYRA-765), che il ticket abbia immagini o no.
  #
  # RESTA VERO il vincolo di capacità: il server AI serve quattro richieste per volta e poi mette in
  # coda, quindi un backfill su tutto il backlog lo satura ancora. Il freno del god (Ai::Feature,
  # chiave `agent_gate`) è l'unico strumento per fermarlo in dieci secondi.
  #
  # FAIL-CLOSED. Nessun ramo di questo service scrive mai `allowed` per difetto: in caso di errore
  # NON scrive nulla, il ticket resta `pending` e `pending` è già escluso dalla coda. Scrivere
  # `blocked` sugli errori sarebbe peggio, non meglio: renderebbe indistinguibile "il modello ha
  # detto no" da "il modello non ha risposto".
  class EvaluateAgentEligibility < ApplicationService
    Verdict = Data.define(:eligibility, :reason, :risks)

    # Mai "pending": pending non è un verdetto, è l'assenza di un verdetto.
    ELIGIBILITIES = %w[allowed blocked].freeze

    RISK_CATEGORIES = %w[
      destructive_production secrets_credentials deploy_infrastructure
      irreversible_data_migration security_auth_change payments_billing
      mass_external_communication underspecified none
    ].freeze

    VERDICT_SCHEMA = {
      type: "object",
      properties: {
        eligibility: {
          type: "string",
          enum: ELIGIBILITIES,
          description: "allowed se un agente AI autonomo può lavorare il ticket senza rischi, altrimenti blocked."
        },
        reason: {
          type: "string",
          description: "1-3 frasi in italiano che citano il punto specifico del ticket o dell'allegato " \
                       "da cui nasce la decisione."
        },
        risks: {
          type: "array",
          description: "Categorie di rischio rilevate. Esattamente [\"none\"] quando il verdetto è allowed.",
          items: { type: "string", enum: RISK_CATEGORIES }
        }
      },
      required: %w[eligibility reason risks]
    }.freeze

    # Il prompt resta hardcoded e NON in i18n: è locale-stabile per costruzione (il verdetto non deve
    # dipendere dalla lingua di chi ha aperto il ticket) e ogni sua modifica deve passare dal bump di
    # Ticketing::AgentEligibilityText::PROMPT_VERSION, che rivaluta il parco.
    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei il gate di sicurezza di un sistema che fa eseguire ticket di sviluppo da agenti AI
      AUTONOMI, senza supervisione umana durante l'esecuzione. L'agente ha accesso al repository del
      progetto, apre branch e pull request, esegue comandi nella propria sandbox.

      Cosa l'agente PUÒ e NON PUÒ fare — tienilo presente prima di decidere, per non immaginare il
      peggio:
      - Opera SOLO su ambienti di sviluppo, test e staging. NON tocca MAI la produzione: non fa
        deploy, non esegue comandi sui server reali, non accede al database di produzione.
      - NON possiede i segreti dell'infrastruttura — chiavi API, token, password, certificati,
        variabili d'ambiente di produzione — né ha accesso al vault che li custodisce. Nominare una
        variabile in un ticket non è possederne il valore.

      Ricevi il contenuto completo di un ticket (titolo, tipo, descrizione, scenari, condizioni di
      completamento, analisi tecnica) e i suoi allegati. Devi decidere UNA cosa sola: se questo
      ticket può essere lavorato da un agente autonomo senza rischi, oppure se richiede una persona.

      Decidi in base al LAVORO che il ticket richiede, non alle parole che contiene. Che il testo
      NOMINI un indirizzo IP, un server, un database, un runtime, un ambiente o una variabile NON è
      di per sé un motivo di blocco: moltissimi problemi che citano l'infrastruttura si diagnosticano
      e si risolvono nel codice (un errore di connessione, per esempio, si affronta spesso su pool,
      timeout o retry). Blocca solo se il lavoro richiede DAVVERO di operare sulla produzione o di
      usare un segreto reale.

      Rispondi "blocked" se il ticket implica, anche solo parzialmente o come effetto collaterale
      plausibile, una di queste categorie di rischio:
      - destructive_production: operazioni distruttive o irreversibili su dati o ambienti di
        produzione (cancellare, troncare, svuotare, "pulire", resettare database, tabelle, bucket,
        code, utenti reali).
      - secrets_credentials: il LAVORO richiede di leggere, scrivere, ruotare o esporre segreti
        reali, chiavi API, token, password, certificati, variabili d'ambiente sensibili; oppure un
        segreto reale compare in chiaro (non oscurato) nel ticket o in un allegato. Il solo NOME di
        un segreto non basta: blocca se il compito è agire su di esso o se il suo valore è esposto.
      - deploy_infrastructure: deploy manuali o rilasci IN PRODUZIONE, modifiche all'infrastruttura
        di produzione — DNS, firewall, server, container, pipeline CI/CD, scaling, backup di
        produzione. Un intervento circoscritto a sviluppo, test o staging NON ricade qui.
      - irreversible_data_migration: migrazioni dati non reversibili, drop di colonne o tabelle,
        backfill massivi, riscritture di dati storici senza rollback.
      - security_auth_change: modifiche ad autenticazione, autorizzazione, permessi, ruoli,
        crittografia, isolamento multi-tenant, rate limiting o controlli anti-abuso.
      - payments_billing: pagamenti, fatturazione, addebiti, rimborsi, abbonamenti, prezzi.
      - mass_external_communication: invio massivo di email, notifiche push o messaggi a utenti reali.
      - underspecified: il ticket è ambiguo, contraddittorio, sottospecificato o troppo vasto perché
        un agente possa capire con certezza il perimetro dell'intervento. Nel dubbio su COSA vada
        fatto, si blocca.

      Rispondi "allowed" solo se il ticket descrive un lavoro di sviluppo ordinario, circoscritto e
      reversibile: correzione di bug applicativi, modifiche a interfaccia o testi, nuova funzionalità
      delimitata, refactoring, test, documentazione — dove l'errore peggiore possibile è una pull
      request da rifiutare.

      Regole:
      - Un valore oscurato, mascherato o redatto (asterischi, «[FILTERED]», «***», puntini al posto
        del contenuto) è un segreto già RIMOSSO per sicurezza: la sua presenza indica che il dato NON
        c'è più, non che sia esposto. Molte segnalazioni automatiche di errore arrivano con campi
        oscurati così, e di per sé non sono un motivo di blocco. Questo vale però per i valori
        OSCURATI: non garantisce che l'intero ticket sia ripulito, e un segreto rimasto in chiaro
        resta un rischio.
      - Nel dubbio, blocca. Un falso blocco costa una revisione umana; un falso permesso può costare
        dati di produzione. Ma "nel dubbio" riguarda COSA va fatto, non le parole usate per
        descriverlo: non bloccare un lavoro lecito solo perché nomina un dettaglio d'infrastruttura.
      - Guarda anche gli allegati: uno screenshot che mostra qualcuno che OPERA su una console di
        produzione o su un pannello di infrastruttura è un segnale di rischio anche se il testo non
        lo dice. Un valore oscurato in un'immagine, invece, resta un segreto rimosso.
      - Se ti viene detto che alcuni allegati non sono stati analizzati, tienine conto: un ticket che
        rimanda a materiale che non puoi vedere è sottospecificato.
      - La motivazione ("reason") è per una persona che deve decidere in dieci secondi se ribaltare
        il tuo verdetto: 1-3 frasi, concrete, che citano il punto specifico del ticket o
        dell'allegato da cui nasce il rischio. Niente formule generiche.
      - Se il verdetto è "allowed", elenca esattamente ["none"] in risks.
      Rispondi in italiano.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    # Client lazy (default nil): costruito dentro #call con la chiave dell'organizzazione del
    # ticket (CYRA-548).
    def initialize(ticket:, client: nil)
      @ticket = ticket
      @client = client
    end

    # Una chiamata sola, con o senza immagini: le foto sono parti in più dello stesso turno.
    #
    # Senza chiave NON si valuta, e non si scrive niente: il ticket resta `pending`, cioè fuori dalla
    # coda degli agenti (CYRA-548). È la stessa fail-closed dell'errore di rete — nessun verdetto
    # inventato, nessun ticket dichiarato lavorabile senza che il vaglio sia davvero avvenuto.
    def call
      # Freno d'emergenza del god PRIMA di spendere una chiamata (Ai::Feature). Il ticket resta
      # `pending`, cioè già fuori dalla coda degli agenti: spegnere il gate è fail-closed per
      # costruzione, esattamente come esaurire i tentativi.
      return Result.err(::Ai::Feature.disabled_error(:agent_gate)) if ::Ai::Feature.disabled?(:agent_gate)

      client = @client || Ai::Llm::Client.new

      args = Ai::Structured.call(client: client, system: SYSTEM_PROMPT, user: prompt_text,
                                 images: inline_image_parts, schema: VERDICT_SCHEMA,
                                 max_output_tokens: Ticketing::Constants::AGENT_ELIGIBILITY_MAX_TOKENS)
      build_verdict(args)
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    rescue JSON::ParserError, TypeError
      Result.err(AppError.new("Valutazione non leggibile", code: "R502-AI-003", status: :bad_gateway))
    rescue Encoding::InvalidByteSequenceError
      Result.err(AppError.new("Un allegato testuale non è UTF-8 valido: converti il file e ricaricalo",
                             code: "R422-AI-007", status: :unprocessable_content))
    end

    private

    # Le immagini nel formato che vuole Ai::Structured. Nessun allegato leggibile = lista vuota, e la
    # chiamata è la stessa con una parte in meno.
    def inline_image_parts
      inline_images.map do |file|
        { mime_type: file.blob.content_type, data: Base64.strict_encode64(file.blob.download) }
      end
    end

    def inline_images
      @inline_images ||= partition_attachments.first.select { |file| image_type?(file.blob.content_type) }
    end

    # Il verdetto viaggia come function-call: lo schema è lo stesso di prima, incapsulato nel tool.
    def prompt_text
      [
        "Progetto: #{@ticket.project.key}",
        Ticketing::AgentEligibilityText.call(ticket: @ticket),
        attachments_section
      ].compact_blank.join("\n")
    end

    # Il modello dev'essere consapevole di ciò che NON ha potuto vedere: senza questa sezione, "ci
    # sono dodici screenshot che non ho analizzato" resterebbe un punto cieco silenzioso invece di
    # diventare un motivo legittimo di `underspecified`.
    def attachments_section
      analyzed, skipped = partition_attachments
      lines = []
      lines << "Allegati analizzati: #{analyzed.map { |file| file.blob.filename.to_s }.join(', ')}" if analyzed.any?
      if skipped.any?
        names = skipped.map { |file| "#{file.blob.filename} (#{file.blob.content_type})" }
        lines << "Allegati NON analizzati, perché oltre i limiti o di tipo non leggibile: #{names.join(', ')}"
      end
      lines << inline_text_section(analyzed)
      lines.compact_blank.join("\n")
    end

    def inline_text_section(analyzed)
      texts = analyzed.select { |file| text_type?(file.blob.content_type) }.map do |file|
        # Active Storage restituisce byte binari: interpretarli PRIMA del troncamento evita di
        # spezzare un carattere multibyte. Il gate non deve valutare testo alterato da sostituzioni.
        body = file.blob.download.to_s.dup.force_encoding(Encoding::UTF_8)
        raise Encoding::InvalidByteSequenceError unless body.valid_encoding?

        body = body.truncate(Ticketing::Constants::AGENT_ELIGIBILITY_MAX_INLINE_TEXT_CHARS)
        "--- #{file.blob.filename} ---\n#{body}"
      end
      return if texts.empty?

      "Contenuto degli allegati testuali:\n#{texts.join("\n")}"
    end

    # Divide gli allegati fra quelli spediti al modello e quelli scartati, applicando in ordine:
    # tipo leggibile dal modello → tetto sul numero → tetto sui byte GREZZI (pre-base64, che gonfia di
    # un terzo verso il limite di 20 MB della richiesta).
    def partition_attachments
      @partition_attachments ||= begin
        analyzed = []
        skipped = []
        budget = Ticketing::Constants::AGENT_ELIGIBILITY_MAX_INLINE_BYTES

        ordered_files.each do |file|
          blob = file.blob
          if blob.nil? || !inlineable_type?(blob.content_type) ||
             analyzed.size >= Ticketing::Constants::AGENT_ELIGIBILITY_MAX_INLINE_ATTACHMENTS ||
             blob.byte_size.to_i > budget
            skipped << file if blob
            next
          end

          budget -= blob.byte_size.to_i
          analyzed << file
        end
        [ analyzed, skipped ]
      end
    end

    def ordered_files
      @ticket.files.includes(:blob).sort_by { |file| [ file.created_at, file.id ] }
    end

    def inlineable_type?(content_type)
      inline_types.include?(content_type)
    end

    def inline_types
      @inline_types ||= Ticketing::Constants::AGENT_ELIGIBILITY_INLINE_IMAGE_TYPES +
                        Ticketing::Constants::AGENT_ELIGIBILITY_INLINE_TEXT_TYPES
    end

    def text_type?(content_type)
      Ticketing::Constants::AGENT_ELIGIBILITY_INLINE_TEXT_TYPES.include?(content_type)
    end

    def image_type?(content_type)
      Ticketing::Constants::AGENT_ELIGIBILITY_INLINE_IMAGE_TYPES.include?(content_type)
    end

    # Un verdetto fuori enum o senza motivazione NON è un verdetto: è un guasto travestito, e come
    # tale non deve produrre una scrittura.
    def build_verdict(payload)
      eligibility = payload["eligibility"].to_s
      reason = payload["reason"].to_s.strip
      return unreadable unless ELIGIBILITIES.include?(eligibility) && reason.present?

      risks = Array(payload["risks"]).map(&:to_s) & RISK_CATEGORIES
      Result.ok(Verdict.new(eligibility: eligibility, reason: reason, risks: risks.presence || %w[none]))
    end

    def unreadable
      Result.err(AppError.new("Verdetto di eleggibilità non leggibile", code: "R502-AI-003", status: :bad_gateway))
    end
  end
end
