# frozen_string_literal: true

module Wikitech
  # "Ask Wikitech" (CYRA-1130/1131): question → cards close in meaning → answer written ONLY from
  # those cards, with citations checked against the candidates. No candidate above the threshold
  # means `insufficient` without calling the model: Wikitech never names a project it does not have.
  class Ask < ApplicationService
    Answer = Data.define(:answer, :entries, :insufficient)

    TOP_K = 8
    # Wider than the shared searches (0.6): a question in other words than the cards ("make games"
    # against "game engine") lands around 0.6. The model reads the candidates and says when none fits.
    MAX_DISTANCE = 0.7
    CONTEXT_CHARS = 900

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You answer questions about a library of software projects and tools that a team collected.
      You receive a question and a list of project cards (id, name, summary, facts, categories,
      repository data). Answer ONLY from those cards: name the useful projects and say in a few
      words why each fits. If the cards do not answer the question, say so plainly.
      Write plain text without Markdown; for a list use lines starting with a dash.
      Return `answer` and `cited_ids` (the ids of the cards your answer uses).
    PROMPT

    SCHEMA = {
      type: "object",
      properties: {
        answer: { type: "string" },
        cited_ids: { type: "array", items: { type: "string" } }
      },
      required: %w[answer]
    }.freeze

    def initialize(scope:, question:, embed_client: nil, chat_client: nil)
      @scope = scope
      @question = question.to_s.strip
      @embed_client = embed_client
      @chat_client = chat_client
    end

    def call
      if @question.blank?
        return Result.err(AppError.new(I18n.t("wikitech.errors.question_blank"), code: "R422-WIKITECH-004"))
      end

      vector = Embeddings::QueryVector.call(query: @question, client: @embed_client)
      return vector if vector.err?

      candidates = rerank(retrieve(vector.value))
      return Result.ok(Answer.new(answer: nil, entries: [], insufficient: true)) if candidates.empty?

      args = Ai::Structured.call(client: @chat_client || Ai::Llm::Client.new, system: SYSTEM_PROMPT,
                                 user: user_text(candidates), schema: SCHEMA)
      Result.ok(answer(args, candidates))
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    end

    private

    def retrieve(vector)
      @scope.reorder(nil).where.not(embedding: nil).current_embedding
            .nearest_neighbors(:embedding, vector, distance: "cosine")
            .limit(TOP_K)
            .select { |entry| entry.neighbor_distance <= MAX_DISTANCE }
    end

    # Cross-encoder for precision; unavailable → cosine order.
    def rerank(candidates)
      return candidates if candidates.empty?

      documents = candidates.map { |entry| "#{entry.name}\n#{entry.summary}".first(CONTEXT_CHARS) }
      ranking = Embeddings::Rerank.call(query: @question, documents: documents, client: @embed_client, min_score: nil)
      return candidates if ranking.err?

      ranking.value.filter_map { |index| candidates[index] }
    end

    def user_text(candidates)
      blocks = candidates.map do |entry|
        [ "id: #{entry.id} | name: #{entry.name} | categories: #{entry.categories.join(', ')}",
          entry.summary.to_s, ("Facts: #{entry.facts.join('; ')}" if entry.facts.any?),
          ("Repository: #{entry.repo_url} · #{entry.license} · #{entry.language}" if entry.repo_url) ]
          .compact.join("\n").first(CONTEXT_CHARS)
      end
      "Question: #{@question}\n\nCards:\n#{blocks.join("\n\n")}"
    end

    def answer(args, candidates)
      allowed = candidates.index_by { |entry| entry.id.to_s }
      cited = Array(args["cited_ids"]).map(&:to_s).uniq.filter_map { |id| allowed[id] }
      Answer.new(answer: args["answer"].to_s.strip, entries: cited, insufficient: false)
    end
  end
end
