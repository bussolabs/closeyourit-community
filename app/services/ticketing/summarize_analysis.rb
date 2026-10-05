# frozen_string_literal: true

module Ticketing
  # Riduce l'analisi tecnica lunga — quella che i vecchi commenti si portano dietro — a una
  # spiegazione che sta nel campo del ticket (CYRA-260). Il testo integrale NON dipende da questo
  # service: è già allegato al ticket come markdown prima che il modello venga interpellato.
  #
  # Gemello di Ticketing::SummarizeComment, con due differenze che contano: il tetto è quello
  # dell'analisi e non quello dei commenti, e qui si chiede una SPIEGAZIONE della soluzione, non il
  # racconto di cosa è stato fatto. Chi apre la scheda vuole capire come funziona la cosa, non
  # leggere il diario di chi l'ha scritta.
  class SummarizeAnalysis < ApplicationService
    # Si chiede meno del tetto: il rimando all'allegato si aggiunge dopo, e un modello che centra il
    # conteggio al carattere non esiste. Il clamp poi è comunque incondizionato.
    TARGET_CHARS = 1_200
    # Oltre questa soglia il testo viene troncato PRIMA di partire. Il più lungo dei gruppi storici
    # misura 11.123 caratteri: il modello non ha bisogno di leggerli tutti per spiegare la soluzione,
    # e il prompt resta di dimensione prevedibile.
    INPUT_CLAMP = 12_000

    SYSTEM_PROMPT = <<~PROMPT
      Sei un redattore tecnico. Ricevi l'analisi tecnica di un ticket, scritta da chi ha lavorato al
      problema, e la riscrivi come spiegazione di AL MASSIMO 1200 caratteri.

      Regole:
      - Italiano, stesso registro dell'originale.
      - Spiega LA SOLUZIONE: qual era il problema, come è stato risolto, cosa cambia. Non raccontare
        la cronaca della lavorazione (branch, commit, rilasci, esiti della CI).
      - Semplice: chi legge deve capire senza aprire il codice. I nomi di file e di classe solo se
        servono a orientarsi, non come elenco.
      - Nessun dettaglio che non sia nell'originale: se non ci sta, taglia. Mai inventare.
      - Non chiudere con puntini di sospensione: la spiegazione è un testo finito.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    SUMMARY_SCHEMA = {
      type: "object",
      properties: {
        summary: { type: "string", description: "La spiegazione, massimo 1200 caratteri." }
      },
      required: [ "summary" ]
    }.freeze

    # `organization:` è OBBLIGATORIA (CYRA-547): il testo da spiegare arriva già estratto, e da una
    # stringa non si risale a chi paga la chiamata. Il client iniettato resta la porta delle prove.
    def initialize(body:, attachment_name:, organization:, client: nil)
      @body = body.to_s
      @attachment_name = attachment_name
      @organization = organization
      @client = client
    end

    # Ripiego quando l'AI è spenta o ha smesso di rispondere. Tronca il testo VERO sul confine di
    # parola: meno informativo di una spiegazione, ma non può essere INFEDELE — e il testo integrale
    # resta comunque nell'allegato, quindi non si perde niente.
    def self.fallback(body:, attachment_name:)
      suffix = suffix_for(attachment_name)
      text = body.to_s.strip
      room = Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS - suffix.length
      return "#{text}#{suffix}" if text.length <= room

      "#{text.truncate(room, separator: " ", omission: "…")}#{suffix}"
    end

    def self.suffix_for(name) = "\n\nDettaglio completo nell'allegato #{name}"

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
      suffix = self.class.suffix_for(@attachment_name)
      room = Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS - suffix.length
      "#{summary.truncate(room, separator: " ", omission: "…")}#{suffix}"
    end

    def empty_error
      AppError.new(I18n.t("ticketing.compaction.errors.empty_summary"), code: "R502-COMPACTION-001",
                                                                       status: :bad_gateway)
    end
  end
end
