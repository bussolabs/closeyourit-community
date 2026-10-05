# frozen_string_literal: true

module Ticketing
  # Analizza una segnalazione bug scritta in testo libero e prova a ricostruire uno o più scenari
  # Given/When/Then/Expected in linguaggio SEMPLICE per umani. Se il testo basta → `complete: true` con
  # almeno uno scenario completo; se manca qualcosa → `complete: false` con domande di chiarimento
  # (loop single-shot lato UI). I dettagli tecnici vanno in `technical_analysis`, fuori dagli scenari.
  #
  # L'output strutturato è imposto dall'API via `response_schema` (Ai::Structured): il modello non
  # può rispondere fuori forma → niente parsing fragile del testo libero.
  # Gli scenari restano input-assist: la verità è il model Ticketing::Ticket.
  class AnalyzeBugReport < ApplicationService
    Analysis = Data.define(:complete, :scenarios, :technical_analysis, :questions)

    STEP_FIELDS = %i[step_given step_when step_then step_expected].freeze

    # La forma che l'API impone alla risposta: solo il sottoinsieme che il server AI accetta
    # (type/properties/required/items/description). Una parola chiave fuori da quello non degrada,
    # fa 400 → R502-LLM-003.
    SCHEMA = {
      type: "object",
      properties: {
        complete: { type: "boolean", description: "true se almeno uno scenario è completo (4 campi)" },
        scenarios: {
          type: "array",
          description: "Uno o più scenari BDD in linguaggio semplice",
          items: {
            type: "object",
            properties: {
              title: { type: "string", description: "Etichetta breve dello scenario" },
              step_given: { type: "string", description: "Contesto/prerequisiti (Given)" },
              step_when: { type: "string", description: "Azione compiuta dall'utente (When)" },
              step_then: { type: "string", description: "Cosa è successo davvero (Then)" },
              step_expected: { type: "string", description: "Cosa ci si aspettava invece (Expected)" }
            }
          }
        },
        technical_analysis: { type: "string", description: "Dettagli tecnici (stack, causa) — fuori dagli scenari" },
        questions: {
          type: "array", items: { type: "string" },
          description: "Domande di chiarimento, presenti solo se complete=false"
        }
      },
      required: %w[complete questions]
    }.freeze

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un assistente che aiuta a scrivere segnalazioni di bug nel formato Given/When/Then/Expected,
      in linguaggio SEMPLICE per umani (come lo racconteresti a voce, niente gergo o stack trace):
      - Given: il contesto e i prerequisiti (ambiente, stato di partenza).
      - When: l'azione concreta compiuta dall'utente.
      - Then: cosa è successo davvero (il comportamento osservato/sbagliato).
      - Expected: cosa l'utente si aspettava invece.

      Ti viene dato il testo libero di una segnalazione. Rispondi con:
      - Ricostruisci UNO o PIÙ scenari (in `scenarios`): aggiungine più di uno se la segnalazione
        descrive percorsi diversi (caso normale, caso limite, errore). Ogni scenario ha un title breve
        e i quattro campi step_given/step_when/step_then/step_expected.
      - Se riesci a ricostruire almeno uno scenario COMPLETO (tutti e quattro i campi), imposta
        `complete: true` e lascia `questions` vuoto.
      - Se anche un solo scenario non è completabile, imposta `complete: false`, compila ciò che sai e
        fornisci da 2 a 4 domande mirate (in `questions`) per ottenere le informazioni mancanti.
      - technical_analysis: eventuali dettagli tecnici (stack, componenti, ipotesi di causa) — SOLO qui,
        fuori dagli scenari. Vuoto se non presenti.
      Rispondi nella stessa lingua del testo della segnalazione.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    # client: lazy (default nil) → costruito dentro #call con la chiave dell'organizzazione del
    # progetto (CYRA-548). Iniettarlo resta la porta delle prove: chi lo passa porta già la sua chiave.
    def initialize(project:, text:, client: nil)
      @project = project
      @text = text.to_s.strip
      @client = client
    end

    def call
      return blank_text_error if @text.blank?
      if ::Ai::Feature.disabled?(:ticket_composition)
        return Result.err(::Ai::Feature.disabled_error(:ticket_composition))
      end

      client = @client || Ai::Llm::Client.new

      # Modello pieno: gli scenari li rilegge chi ha scritto la segnalazione, e una ricostruzione
      # approssimativa costa più tempo di quanto ne faccia risparmiare.
      args = Ai::Structured.call(client: client, system: SYSTEM_PROMPT, user: user_prompt,
                                 schema: SCHEMA, model: Ai::Configuration.current.chat_model)
      Result.ok(build_analysis(args))
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    rescue JSON::ParserError, TypeError
      Result.err(AppError.new(I18n.t("member.tickets.analyze.errors.unreadable"),
                              code: "R502-AI-003", status: :bad_gateway))
    end

    private

    def blank_text_error
      Result.err(AppError.new(I18n.t("member.tickets.analyze.errors.blank"),
                              code: "R422-TICKET-003", status: :unprocessable_content))
    end

    def user_prompt
      "Progetto: #{@project.name}\n\nSegnalazione:\n#{@text}"
    end

    def build_analysis(args)
      scenarios = ComposeTicket.parse_scenarios(args["scenarios"])
      questions = Array(args["questions"]).map { |question| question.to_s.strip }.reject(&:blank?)
      # complete solo se il modello lo dichiara E c'è almeno uno scenario con tutti e 4 i campi.
      full = scenarios.any? { |scenario| STEP_FIELDS.all? { |field| scenario[field].present? } }
      complete = ActiveModel::Type::Boolean.new.cast(args["complete"]) && full

      # Troncata al tetto del ticket: la analisi pre-compila il form, non deve renderlo non salvabile.
      Analysis.new(complete:, scenarios:,
                   technical_analysis: args["technical_analysis"].to_s.strip.presence
                                           &.truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS),
                   questions: complete ? [] : questions)
    end
  end
end
