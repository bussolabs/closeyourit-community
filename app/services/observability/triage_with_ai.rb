# frozen_string_literal: true

module Observability
  # Base condivisa del triage assistito AI di un gruppo di monitoring: l'AI propone un verdetto
  # vincolato da uno schema (`response_schema` via Ai::Structured, stesso pattern di
  # Ticketing::AnalyzeBugReport). È SOLO un consiglio: l'umano applica con la Triage /
  # PromoteToTicket del dominio. Le sottoclassi forniscono il system prompt, il contesto utente
  # (dati del gruppo), lo schema della risposta e la costruzione del verdetto. client lazy
  # (default nil): costruito dentro #call con la chiave dell'organizzazione a cui appartiene il
  # progetto del gruppo (CYRA-548).
  class TriageWithAi < ApplicationService
    def initialize(group:, client: nil)
      @group = group
      @client = client
    end

    def call
      return Result.err(Ai::Feature.disabled_error(:triage)) if Ai::Feature.disabled?(:triage)

      client = @client || Ai::Llm::Client.new

      # Modello strutturato di default: qui si estrae un verdetto a campi chiusi, non si scrive prosa.
      args = Ai::Structured.call(client: client, system: system_prompt, user: user_context, schema: schema)
      Result.ok(build_triage(args))
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

    def clean(value) = value.to_s.strip.presence
    def pick(value, allowed) = allowed.include?(value.to_s) ? value.to_s : nil

    def system_prompt = raise NotImplementedError, "#{self.class} deve definire system_prompt"
    def user_context = raise NotImplementedError, "#{self.class} deve definire user_context"
    def schema = raise NotImplementedError, "#{self.class} deve definire schema"
    def build_triage(_args) = raise NotImplementedError, "#{self.class} deve definire build_triage"
  end
end
