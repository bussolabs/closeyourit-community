# frozen_string_literal: true

module Ticketing
  # RAG "chiedi ai ticket": domanda in linguaggio naturale → retrieval semantico sui ticket
  # VISIBILI all'account (embed + coseno + rerank) → risposta LLM fondata SOLO sul contesto,
  # con citazioni verificate (anti-allucinazione: cited_ids ∩ candidati).
  #
  # Guardrail: zero candidati sopra soglia → `insufficient: true` SENZA chiamare l'LLM
  # (niente risposte inventate su contesto vuoto, niente token sprecati).
  class AskTickets < ApplicationService
    Answer = Data.define(:answer, :tickets, :insufficient)

    TOP_K = 8
    MAX_DISTANCE = 0.55
    # Corpo del ticket nel prompt (description/GWT clampati) — budget token del contesto.
    CONTEXT_CHARS = 700
    # Commenti recenti nel prompt a retrieval-time (NON stanno nell'embedding — dati live).
    RECENT_COMMENTS = 2

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un assistente che risponde a domande sui ticket di un team di sviluppo. Ricevi una
      domanda e una lista di ticket pertinenti (id, codice, titolo, stato, corpo, commenti).
      Produci SEMPRE una risposta strutturata con due campi:
      - `answer`: la risposta, basata ESCLUSIVAMENTE sui ticket forniti. Cita i ticket rilevanti
        nel testo col loro codice tra parentesi quadre, es. [ABC-12]. Se il contesto non basta
        per rispondere, dillo esplicitamente.
      - `cited_ids`: gli id (presi dalla lista) dei ticket su cui si fonda la risposta.
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
          description: "Id (presi dalla lista) dei ticket citati"
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
    # che teneva occupato un thread web per minuti — CYRA-275): la risposta arriva in una sola
    # connessione e ritorna già l'Hash degli argomenti parsato, senza tool-call da decodificare.
    def call
      return blank_question_error if @question.blank?

      vector = Embeddings::EmbedText.call(text: @question, client: @embed_client)
      return vector if vector.err?

      candidates = rerank(retrieve(vector.value))
      return Result.ok(Answer.new(answer: nil, tickets: [], insufficient: true)) if candidates.empty?

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
      Result.err(AppError.new(I18n.t("member.tickets.ask.errors.blank"),
                              code: "R422-TICKET-005", status: :unprocessable_content))
    end

    def retrieve(vector)
      @scope.reorder(nil).where.not(embedding: nil).current_embedding
            .includes(:status, :project)
            .nearest_neighbors(:embedding, vector, distance: "cosine")
            .limit(TOP_K)
            .select { |ticket| ticket.neighbor_distance <= MAX_DISTANCE }
    end

    # Rerank cross-encoder (precision). Errore → ordine coseno: perdere precisione non
    # giustifica perdere la feature.
    def rerank(candidates)
      return candidates if candidates.empty?

      documents = candidates.map { |t| "#{t.title}\n#{t.description}".first(CONTEXT_CHARS) }
      client = @embed_client || Ai::Embedding::Client.new
      ranking = client.rerank(query: @question, documents: documents)
      ranking.filter_map { |item| candidates[item[:index]] }
    rescue Ai::Embedding::Client::Error, KeyError
      candidates
    end

    # Il system prompt viaggia a parte (system:), qui solo il turno utente.
    def contents(candidates)
      blocks = candidates.map { |ticket| context_block(ticket) }.join("\n\n")
      [ { role: "user", parts: [ { text: "Domanda: #{@question}\n\nTicket pertinenti:\n#{blocks}" } ] } ]
    end

    def context_block(ticket)
      body = Ticketing::EmbeddingText.call(ticket: ticket).first(CONTEXT_CHARS)
      comments = ticket.comments.order(created_at: :desc).limit(RECENT_COMMENTS).map do |comment|
        "Commento (#{comment.author&.name}): #{comment.body.to_s.first(200)}"
      end
      [ "id: #{ticket.id} | codice: #{ticket.code} | stato: #{ticket.status&.label}",
        body, *comments ].join("\n")
    end

    # Citazioni = SOLO id realmente candidati (difesa contro id allucinati o di altri progetti).
    def build_answer(args, candidates)
      allowed = candidates.index_by { |ticket| ticket.id.to_s }
      cited = Array(args["cited_ids"]).map(&:to_s).uniq.filter_map { |id| allowed[id] }
      Result.ok(Answer.new(answer: args["answer"].to_s.strip, tickets: cited, insufficient: false))
    end
  end
end
