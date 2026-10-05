# frozen_string_literal: true

module Errors
  # Clustering "errori simili": il fingerprint raggruppa solo le occorrenze IDENTICHE; qui l'AI
  # individua gruppi DIVERSI dello stesso progetto con la STESSA causa radice (es. "connection pool
  # esaurito" che si manifesta in punti diversi). È un suggerimento read-only. Anti-allucinazione:
  # i gruppi tornati dall'AI sono ricaricati solo se erano davvero nel set candidato del progetto.
  class FindSimilarGroups < ApplicationService
    Similar = Data.define(:groups, :reason)

    CANDIDATE_LIMIT = 30
    # Distanza coseno massima perché un gruppo sia candidato "simile" (embeddings = recall).
    MAX_CANDIDATE_DISTANCE = 0.5

    # La forma che l'API impone alla risposta: solo il sottoinsieme che il server AI accetta.
    SCHEMA = {
      type: "object",
      properties: {
        related_ids: {
          type: "array", items: { type: "string" },
          description: "Id (presi dalla lista) con la stessa causa del riferimento"
        },
        reason: { type: "string", description: "Criterio del raggruppamento" }
      },
      required: %w[related_ids]
    }.freeze

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un assistente che raggruppa errori con la STESSA causa radice. Ricevi un errore di riferimento
      e una lista di altri errori dello stesso progetto (id, titolo, posizione). Individua quali, tra
      quelli in lista, hanno verosimilmente la stessa causa del riferimento. Rispondi con:
      - related_ids: gli id (presi DALLA lista) che condividono la causa del riferimento; vuoto se nessuno.
      - reason: una frase che spiega il criterio del raggruppamento.
      Usa SOLO id presenti nella lista. Rispondi in italiano.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    def initialize(group:, client: nil)
      @group = group
      @client = client
    end

    def call
      return Result.err(Ai::Feature.disabled_error(:triage)) if Ai::Feature.disabled?(:triage)

      # CYRA-168: se il gruppo di riferimento porta ancora il vettore di una versione superata
      # (re-embed in corso), i suoi vicini coseno contro righe di versione corrente sarebbero privi
      # di senso → degradiamo a "nessun simile" (niente candidati, niente LLM) invece di mescolare.
      return Result.ok(Similar.new(groups: [], reason: nil)) if stale_reference?

      candidates = candidate_groups
      return Result.ok(Similar.new(groups: [], reason: nil)) if candidates.empty?

      client = @client || Ai::Llm::Client.new

      args = Ai::Structured.call(client: client, system: SYSTEM_PROMPT,
                                 user: user_prompt(candidates), schema: SCHEMA)
      Result.ok(build_similar(args, candidates))
    rescue Ai::Llm::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
    rescue JSON::ParserError, TypeError
      Result.err(AppError.new(I18n.t("member.monitoring.triage_ai.errors.unreadable"),
                              code: "R502-AI-003", status: :bad_gateway))
    end

    private

    # Riferimento stale = ha un embedding persistito ma di versione diversa dalla corrente. Un
    # riferimento NON embeddato non è stale: il ramo frequenza (sotto) resta la rete di sicurezza.
    def stale_reference?
      @group.embedding.present? &&
        @group.embedding_version != Ai::Configuration.current.embedding_version
    end

    # Candidati per il verdetto LLM (embeddings = recall, LLM = precision + reason).
    # Primario: vicini semantici via coseno — supera il bias "top-N per frequenza" (un errore
    # raro ma identico entrava mai nei candidati). Fallback al ramo frequenza quando il gruppo
    # di riferimento non è ancora embeddato o nessun candidato lo è (backfill in corso): la
    # feature non si spegne mai. Lo scoping per project_id resta la frontiera anti-leak.
    def candidate_groups
      scope = Errors::Group.status_unresolved
                           .where(project_id: @group.project_id)
                           .where.not(id: @group.id)

      if @group.embedding.present?
        semantic = scope.where.not(embedding: nil).current_embedding
                        .nearest_neighbors(:embedding, @group.embedding, distance: "cosine")
                        .limit(CANDIDATE_LIMIT)
                        .select { |group| group.neighbor_distance <= MAX_CANDIDATE_DISTANCE }
        return semantic if semantic.any?
      end

      scope.order(events_count: :desc).limit(CANDIDATE_LIMIT).to_a
    end

    def user_prompt(candidates)
      list = candidates.map { |group| "- #{group.id} | #{group.title} | #{group.culprit}" }.join("\n")
      reference = "Errore di riferimento:\n#{@group.title} | #{@group.culprit}"
      "#{reference}\n\nAltri errori del progetto:\n#{list}"
    end

    # Ricarica SOLO gli id realmente candidati: difesa contro id allucinati o di altri progetti.
    def build_similar(args, candidates)
      allowed = candidates.index_by { |group| group.id.to_s }
      ids = Array(args["related_ids"]).map(&:to_s).uniq
      groups = ids.filter_map { |id| allowed[id] }
      Similar.new(groups:, reason: args["reason"].to_s.strip.presence)
    end
  end
end
