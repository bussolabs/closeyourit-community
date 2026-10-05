# frozen_string_literal: true

module Embeddings
  # Trasforma un testo nel suo embedding (Array<Float> di dimensione fissa 1024) via servizio
  # Ai::Embedding::Client (LiteLLM sul server AI di casa). Unico punto di normalizzazione input (strip + clamp) ed enforcement
  # della dimensione: i chiamanti ricevono un vettore già valido per la colonna vector(1024).
  #
  # I messaggi d'errore sono tecnici (non user-facing): tutte le feature degradano in silenzio
  # quando il servizio è giù — la UI non mostra mai questi errori così come sono.
  class EmbedText < ApplicationService
    # client: lazy (default nil) → istanziato dentro #call così un eventuale errore di config
    # (ENV AI_API_KEY/EMBED_BASE_URL mancante → KeyError) cade nel rescue, mai un 500.
    # label: identifica il record nel log quando il testo va tagliato (vedi #clamped_text).
    def initialize(text:, label: nil, client: nil)
      @text = text.to_s.strip
      @label = label
      @client = client
    end

    def call
      return blank_text_error if @text.blank?
      return Result.err(Ai::Feature.disabled_error(:embeddings)) if Ai::Feature.disabled?(:embeddings)

      client = @client || Ai::Embedding::Client.new
      vector = client.embed(input: clamped_text).first
      return wrong_dimension_error(vector) unless vector.length == Ai::Configuration.current.embedding_dimensions

      Result.ok(vector)
    rescue Ai::Embedding::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue KeyError
      # Config embedding mancante (EMBED_* non in env) → errore pulito, mai 500.
      Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-AI-002", status: :bad_gateway))
    end

    private

    # Il clamp è una PERDITA di segnale: ciò che sta oltre non entra nel vettore, quindi smette di
    # essere cercabile senza che nessuno se ne accorga. I tetti di lunghezza (concern LengthBudget su
    # Knowledge::Page e Ticketing::Ticket) servono proprio a non arrivarci; dove non sono
    # dimostrabili — un ticket con molti scenari, un gruppo d'errore con uno stack lungo — il taglio
    # deve almeno lasciare traccia. Rails.logger.warn finisce nei Logs via closeyourit-ruby.
    def clamped_text
      return @text if @text.length <= Ai::Constants::EMBED_MAX_CHARS

      Rails.logger.warn(
        "Embedding troncato#{" (#{@label})" if @label.present?}: " \
        "#{@text.length} caratteri → #{Ai::Constants::EMBED_MAX_CHARS}"
      )
      @text.first(Ai::Constants::EMBED_MAX_CHARS)
    end

    def blank_text_error
      Result.err(AppError.new("Testo da embeddare vuoto", code: "R422-AI-002", status: :unprocessable_content))
    end

    def wrong_dimension_error(vector)
      Result.err(AppError.new("Embedding di dimensione inattesa (#{vector.length})",
                              code: "R502-AI-005", status: :bad_gateway))
    end
  end
end
