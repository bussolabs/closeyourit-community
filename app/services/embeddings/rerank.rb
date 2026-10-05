# frozen_string_literal: true

module Embeddings
  # Rerank cross-encoder + taglio di pertinenza per le ricerche INTERATTIVE (ticket, conoscenza,
  # idee). Un posto solo: prima ogni dominio aveva la sua copia, e il taglio mancava in tutte e tre.
  #
  # Result.ok(indexes) = posizioni di `documents` ordinate per pertinenza e già ripulite dal
  # rumore (lista vuota = niente di pertinente: è una risposta, non un guasto).
  # Result.err = rerank non disponibile — servizio giù, non configurato, o più lento del tetto di
  # attesa: il chiamante degrada all'ordine coseno. Perdere precisione non giustifica perdere la
  # feature, e soprattutto non giustifica tenere occupato un thread web finché il servizio non
  # decide di rispondere.
  class Rerank < ApplicationService
    def initialize(query:, documents:, client: nil)
      @query = query.to_s
      @documents = documents
      @client = client
    end

    def call
      return Result.ok([]) if @documents.blank?

      client = @client || Ai::Embedding::Client.new
      ranking = client.rerank(query: @query, documents: @documents,
                              read_timeout: Ai::Constants::RERANK_READ_TIMEOUT_SECONDS)
      Result.ok(Relevance.relevant_indexes(ranking))
    rescue Ai::Embedding::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # Config embedding mancante (EMBED_* non in env) → errore pulito, mai 500.
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-AI-002", status: :bad_gateway))
    end
  end
end
