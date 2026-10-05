# frozen_string_literal: true

module Ticketing
  # Riduce un commento storico lungo al tetto dei commenti, lasciando in discussione una frase che si
  # legge (CYRA-222). Il testo integrale NON dipende da questo service: è già al sicuro in una
  # versione del resoconto e in `original_body` prima che il modello venga interpellato.
  #
  # Server AI sincrono e non Proxanything: qui si compattano centinaia di commenti in fila, e un client
  # async 202 + polling raddoppierebbe le chiamate per ogni riga senza dare niente in cambio.
  class SummarizeComment < ApplicationService
    # Si chiede meno del tetto: il suffisso di rimando al resoconto va aggiunto dopo, e un modello che
    # centra il conteggio al carattere non esiste. Il clamp poi è comunque incondizionato.
    TARGET_CHARS = 200
    # Oltre questa soglia il commento viene troncato PRIMA di partire: un resoconto da 7.600 caratteri
    # non ha bisogno di essere letto tutto per essere riassunto in due frasi, e il prompt resta corto.
    INPUT_CLAMP = 6_000

    SYSTEM_PROMPT = <<~PROMPT
      Sei un redattore tecnico. Ricevi il commento di un ticket, scritto da chi ha lavorato il ticket.
      Riscrivilo in un riassunto di AL MASSIMO 200 caratteri, che dovrà stare in un commento da 240.

      Regole:
      - Italiano, stessa lingua e stesso registro dell'originale.
      - Dì che cosa è stato fatto e con quale esito. Niente preamboli, niente "in questo commento".
      - Nessun dettaglio che non sia nell'originale: se non ci sta, taglia, non riassumere a vanvera.
      - Niente nomi di file, classi, comandi o codici: il dettaglio resta nel resoconto completo.
      - Non chiudere con puntini di sospensione: il riassunto è una frase finita.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    SUMMARY_SCHEMA = {
      type: "object",
      properties: {
        summary: { type: "string", description: "Il riassunto, massimo 200 caratteri." }
      },
      required: [ "summary" ]
    }.freeze

    # `organization:` è OBBLIGATORIA (CYRA-547): il commento arriva già come stringa, e da una stringa
    # non si risale a chi paga la chiamata. Il client iniettato resta la porta delle prove.
    def initialize(body:, report_version:, organization:, client: nil)
      @body = body.to_s
      @report_version = report_version
      @organization = organization
      @client = client
    end

    # Ripiego quando l'AI è spenta o ha smesso di rispondere. Tronca il testo VERO sul confine di
    # parola: un troncamento è meno informativo di un riassunto ma non può essere INFEDELE, e lasciare
    # commenti non compattati in eterno è peggio di entrambi.
    def self.fallback(body:, report_version:)
      suffix = suffix_for(report_version)
      text = body.to_s.strip
      return text if text.length <= Ticketing::Constants::COMMENT_MAX_CHARS

      "#{text.truncate(Ticketing::Constants::COMMENT_MAX_CHARS - suffix.length, separator: " ", omission: "…")}#{suffix}"
    end

    def self.suffix_for(version) = " (resoconto v#{version})"

    def call
      return Result.err(Ai::Feature.disabled_error(:comment_compaction)) if Ai::Feature.disabled?(:comment_compaction)

      client = @client || Ai::Llm::Client.new

      summary = request_summary(client)
      return Result.err(empty_error) if summary.blank?

      Result.ok(clamp(summary))
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    end

    private

    def request_summary(client)
      payload = client.generate_content(
        system: SYSTEM_PROMPT,
        contents: [ { role: "user", parts: [ { text: @body.truncate(INPUT_CLAMP) } ] } ],
        response_schema: SUMMARY_SCHEMA
      )
      payload["summary"].to_s.strip
    end

    # Clamp incondizionato: non ci si fida del modello sul conteggio dei caratteri, mai.
    def clamp(summary)
      suffix = self.class.suffix_for(@report_version)
      room = Ticketing::Constants::COMMENT_MAX_CHARS - suffix.length
      "#{summary.truncate(room, separator: " ", omission: "…")}#{suffix}"
    end

    def empty_error
      AppError.new(I18n.t("ticketing.compaction.errors.empty_summary"), code: "R502-COMPACTION-001",
                                                                       status: :bad_gateway)
    end
  end
end
