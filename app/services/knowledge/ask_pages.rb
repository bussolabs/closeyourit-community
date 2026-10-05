# frozen_string_literal: true

module Knowledge
  # RAG "chiedi alla knowledge base": domanda in linguaggio naturale → retrieval semantico sulle
  # pagine VISIBILI all'account (embed + coseno + rerank) → risposta LLM fondata SOLO sul
  # contesto, con citazioni verificate (anti-allucinazione: cited_ids ∩ candidati).
  # Clone di Ticketing::AskTickets sulle pagine KB.
  #
  # Guardrail: zero candidati sopra soglia → `insufficient: true` SENZA chiamare l'LLM.
  class AskPages < ApplicationService
    Answer = Data.define(:answer, :pages, :insufficient)

    TOP_K = 8
    MAX_DISTANCE = 0.55
    # Corpo della pagina nel prompt (clampato) — budget token del contesto.
    CONTEXT_CHARS = 900
    # Sezione tecnica nel prompt: budget PROPRIO, indipendente dal corpo (CYRA-252). Il tecnico
    # ENTRA nell'embedding (Knowledge::EmbeddingText) ed è spesso ciò che rende la pagina il
    # candidato migliore, ma finora non arrivava al modello: la pagina veniva trovata e la risposta
    # era «contesto insufficiente». Un budget separato dal corpo garantisce che il tecnico arrivi
    # SEMPRE per intero (tetto del campo), qualunque sia la lunghezza del corpo.
    TECH_SPEC_CHARS = Knowledge::Constants::TECH_SPEC_MAX_CHARS

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un assistente che risponde a domande sulla knowledge base di un team di sviluppo
      (note, decisioni architetturali, guide). Ricevi una domanda e una lista di pagine
      pertinenti (id, titolo, tipo, contenuto, dettagli tecnici). Produci SEMPRE una risposta
      strutturata con due campi:
      - `answer`: la risposta, basata ESCLUSIVAMENTE sulle pagine fornite. Cita le pagine
        rilevanti nel testo col loro titolo tra parentesi quadre, es. [Scelta database].
        Se il contesto non basta per rispondere, dillo esplicitamente.
      - `cited_ids`: gli id (presi dalla lista) delle pagine su cui si fonda la risposta.
      Rispondi nella stessa lingua della domanda.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    # Argomenti attesi dal modello (structured output del server AI): risposta + id citati.
    RESPONSE_SCHEMA = {
      type: "object",
      properties: {
        answer: { type: "string", description: "La risposta alla domanda" },
        cited_ids: {
          type: "array", items: { type: "string" },
          description: "Id (presi dalla lista) delle pagine citate"
        }
      },
      required: %w[answer]
    }.freeze

    # `organization:` è OBBLIGATORIA (CYRA-547): è chi paga la risposta. Lo scope da solo non basta a
    # ricavarla — può essere vuoto, e da un relation vuoto non si risale a nessuna organizzazione.
    # Il client lazy (default nil) resta la porta delle prove: chi lo passa porta già la sua chiave.
    def initialize(scope:, question:, organization:, embed_client: nil, chat_client: nil)
      @scope = scope
      @question = question.to_s.strip
      @organization = organization
      @embed_client = embed_client
      @chat_client = chat_client
    end

    # Server AI strutturato (generate_content) e non più Proxanything (202 + polling, worst case ~730s
    # che teneva occupato un thread web per minuti — CYRA-275).
    def call
      return blank_question_error if @question.blank?

      # Con micro-cache: la stessa domanda serve anche il "secondo salto" (pagine correlate alle
      # citate, Knowledge::RelatedPages) senza un secondo giro al servizio embedding.
      vector = Embeddings::QueryVector.call(query: @question, client: @embed_client)
      return vector if vector.err?

      candidates = rerank(retrieve(vector.value))
      return Result.ok(Answer.new(answer: nil, pages: [], insufficient: true)) if candidates.empty?

      chat_client = @chat_client || Ai::Llm::Client.new

      args = chat_client.generate_content(system: SYSTEM_PROMPT, contents: contents(candidates),
                                          response_schema: RESPONSE_SCHEMA)
      build_answer(args, candidates)
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    end

    private

    def blank_question_error
      Result.err(AppError.new(I18n.t("member.knowledge.ask.errors.blank"),
                              code: "R422-KNOWLEDGE-003", status: :unprocessable_content))
    end

    def retrieve(vector)
      @scope.reorder(nil).where.not(embedding: nil).current_embedding
            .includes(:projects)
            .nearest_neighbors(:embedding, vector, distance: "cosine")
            .limit(TOP_K)
            .select { |page| page.neighbor_distance <= MAX_DISTANCE }
    end

    # Rerank cross-encoder (precision). Errore → ordine coseno: perdere precisione non
    # giustifica perdere la feature.
    def rerank(candidates)
      return candidates if candidates.empty?

      documents = candidates.map { |page| "#{page.title}\n#{page.body}".first(CONTEXT_CHARS) }
      client = @embed_client || Ai::Embedding::Client.new
      ranking = client.rerank(query: @question, documents: documents)
      ranking.filter_map { |item| candidates[item[:index]] }
    rescue Ai::Embedding::Client::Error, KeyError
      candidates
    end

    # Il system prompt viaggia a parte (system:), qui solo il turno utente.
    def contents(candidates)
      blocks = candidates.map { |page| context_block(page) }.join("\n\n")
      [ { role: "user", parts: [ { text: "Domanda: #{@question}\n\nPagine pertinenti:\n#{blocks}" } ] } ]
    end

    def context_block(page)
      lines = [ "id: #{page.id} | titolo: #{page.title} | tipo: #{page.kind}",
                page.body.to_s.first(CONTEXT_CHARS) ]
      # Etichetta identica a Knowledge::EmbeddingText: il modello legge il tecnico con lo stesso
      # nome con cui è stato indicizzato. Solo se presente → pagine senza tecnico invariate.
      lines << "Dettagli tecnici: #{page.tech_spec.first(TECH_SPEC_CHARS)}" if page.tech_spec.present?
      lines.join("\n")
    end

    # Citazioni = SOLO id realmente candidati (difesa contro id allucinati o fuori scope).
    def build_answer(args, candidates)
      allowed = candidates.index_by { |page| page.id.to_s }
      cited = Array(args["cited_ids"]).map(&:to_s).uniq.filter_map { |id| allowed[id] }
      Result.ok(Answer.new(answer: args["answer"].to_s.strip, pages: cited, insufficient: false))
    end
  end
end
