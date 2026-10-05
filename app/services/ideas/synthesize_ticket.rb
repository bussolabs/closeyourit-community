# frozen_string_literal: true

module Ideas
  # Sintetizza un'idea + la discussione del team in una bozza di ticket (title + description
  # markdown) via LLM. È SOLO una bozza: l'umano la rivede nel form di conversione e il ticket
  # nasce da Ideas::PromoteToTicket. Output strutturato via tool calling (`tool_choice:
  # "required"`), stesso pattern di Ticketing::AnalyzeBugReport / Errors::TriageWithAi.
  class SynthesizeTicket < ApplicationService
    Draft = Data.define(:title, :description)

    TITLE_LIMIT = 120
    COMMENTS_LIMIT = 30
    # CYRA-371 — alzato con il tetto del commento (Ideas::Constants::COMMENT_MAX_CHARS): a 500 la
    # sintesi leggeva il primo capoverso di un ragionamento e buttava via la parte in cui si decide.
    # Non è il tetto intero perché il budget qui è il contesto: COMMENTS_LIMIT commenti a questa
    # misura restano una manciata di migliaia di token, trenta commenti da 5.000 caratteri no.
    COMMENT_CLAMP = 1_500
    BODY_CLAMP = 4000
    CASES_LIMIT = 20
    CASE_CLAMP = 500
    # La description sintetizza idea + discussione: serve più spazio del default (1024).
    MAX_TOKENS = 2048

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un assistente che trasforma un'idea di prodotto e la discussione del team in un ticket
      azionabile. Ricevi l'idea (titolo, problema, soluzione proposta, stakeholder, case/esempi
      concreti) e i commenti del team in ordine cronologico. Produci SEMPRE una risposta
      strutturata con:
      - title: titolo conciso e azionabile del ticket (max #{TITLE_LIMIT} caratteri, senza prefissi tipo "Idea:").
      - description: descrizione completa in markdown (max #{Ticketing::Constants::DESCRIPTION_MAX_CHARS} caratteri) che UNISCE l'idea e la discussione:
        cosa fare e perché (il valore per l'utente), le decisioni e precisazioni emerse dai
        commenti, requisiti e casi limite citati. Non inventare requisiti non presenti nel
        testo; non citare i nomi degli autori dei commenti.
      Rispondi nella stessa lingua dell'idea.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    # Argomenti attesi dal modello (structured output del server AI): bozza title + description.
    RESPONSE_SCHEMA = {
      type: "object",
      properties: {
        title: { type: "string", description: "Titolo conciso e azionabile del ticket" },
        description: { type: "string", description: "Descrizione completa in markdown (idea + discussione)" }
      },
      required: %w[title description]
    }.freeze

    # client lazy (default nil): costruito dentro #call con la chiave dell'organizzazione del progetto
    # dell'idea (CYRA-547). Iniettarlo resta la porta delle prove: chi lo passa porta già la sua chiave.
    def initialize(idea:, client: nil)
      @idea = idea
      @client = client
    end

    # Server AI strutturato (generate_content) e non più Proxanything (202 + polling, worst case ~730s
    # che teneva occupato un thread web/worker per minuti — CYRA-275): ritorna già l'Hash della bozza.
    def call
      if ::Ai::Feature.disabled?(:ticket_composition)
        return Result.err(::Ai::Feature.disabled_error(:ticket_composition))
      end

      client = @client || Ai::Llm::Client.new

      args = client.generate_content(system: SYSTEM_PROMPT, contents:, response_schema: RESPONSE_SCHEMA,
                                     max_output_tokens: MAX_TOKENS)
      build_draft(args)
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    end

    private

    # Il system prompt viaggia a parte (system:), qui solo il turno utente.
    def contents
      [ { role: "user", parts: [ { text: idea_context } ] } ]
    end

    def idea_context
      [
        "Idea: #{@idea.title}",
        "Problema:\n#{clamp(@idea.problem, BODY_CLAMP)}",
        solution_line,
        monetization_line,
        risks_line,
        stakeholders_line,
        links_block,
        cases_block,
        comments_block
      ].compact.join("\n\n")
    end

    def solution_line
      return if @idea.solution.blank?

      "Soluzione proposta:\n#{clamp(@idea.solution, BODY_CLAMP)}"
    end

    # CYRA-845 — come si ripaga e cosa la frena: entrano nella bozza del ticket, altrimenti la
    # conversione le perderebbe (prima vivevano nei commenti e ci arrivavano da lì).
    def monetization_line
      return if @idea.monetization.blank?

      "Monetizzazione:\n#{clamp(@idea.monetization, BODY_CLAMP)}"
    end

    def risks_line
      return if @idea.risks.blank?

      "Rischi e vincoli:\n#{clamp(@idea.risks, BODY_CLAMP)}"
    end

    # Idee collegate, per titolo: la base di cui questa è evoluzione, le evoluzioni, i parenti alla
    # pari. Solo i titoli: il ticket nasce da QUESTA idea, le altre restano un riferimento.
    def links_block
      lines = []
      lines << "- Evolve l'idea: #{@idea.parent.title}" if @idea.parent
      @idea.evolutions.each { |idea| lines << "- Evoluzione proposta: #{idea.title}" }
      @idea.related_ideas.each { |idea| lines << "- Idea collegata: #{idea.title}" }
      return if lines.empty?

      "Idee collegate:\n#{lines.join("\n")}"
    end

    def stakeholders_line
      return if @idea.stakeholders.empty?

      "Stakeholder (per chi è utile): #{@idea.stakeholders.join(', ')}"
    end

    # Case (esempi/scenari concreti) clampati come i commenti; assente se non ce ne sono.
    def cases_block
      cases = @idea.cases.first(CASES_LIMIT)
      return if cases.empty?

      lines = cases.map do |idea_case|
        description = clamp(idea_case.description, CASE_CLAMP)
        description.present? ? "- #{idea_case.title}: #{description}" : "- #{idea_case.title}"
      end
      "Case (esempi concreti):\n#{lines.join("\n")}"
    end

    # Commenti cronologici (l'ordine è quello dell'associazione), clampati per non sfondare il
    # contesto: al massimo COMMENTS_LIMIT commenti, ognuno a COMMENT_CLAMP caratteri.
    def comments_block
      comments = @idea.comments.includes(:author).first(COMMENTS_LIMIT)
      return "Nessun commento del team." if comments.empty?

      lines = comments.map do |comment|
        author = comment.author&.name.presence || "Ex membro"
        "- #{author} (#{comment.created_at.to_date}): #{clamp(comment.body, COMMENT_CLAMP)}"
      end
      "Commenti del team (in ordine cronologico):\n#{lines.join("\n")}"
    end

    def clamp(text, limit)
      text.to_s.strip.truncate(limit)
    end

    # title vuoto → fallback sul titolo dell'idea; description vuota → output inutilizzabile.
    # Entrambi troncati al tetto del ticket: il prompt lo chiede, ma un modello che sfora non deve
    # produrre una bozza che il form rifiuta e l'utente deve tagliare a mano.
    def build_draft(args)
      title = args["title"].to_s.strip.presence || @idea.title
      description = args["description"].to_s.strip
      return unreadable if description.blank?

      Result.ok(Draft.new(title: title.truncate(TITLE_LIMIT),
                          description: description.truncate(Ticketing::Constants::DESCRIPTION_MAX_CHARS)))
    end

    def unreadable
      Result.err(AppError.new(I18n.t("ideas.errors.ai_unreadable"),
                              code: "R502-AI-003", status: :bad_gateway))
    end
  end
end
