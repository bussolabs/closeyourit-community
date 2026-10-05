# frozen_string_literal: true

module Metrics
  # Triage assistito AI di un gruppo-metrica (slow query / slow method / performance issue): l'AI
  # propone categoria, severità, causa probabile, un fix tecnico suggerito e se vale un ticket.
  # Specializza Observability::TriageWithAi. È SOLO un consiglio: l'umano applica con
  # Metrics::PromoteToTicket. Output vincolato da uno schema (`response_schema`).
  class TriageWithAi < Observability::TriageWithAi
    Triage = Data.define(:category, :severity, :root_cause, :suggested_fix, :suggested_action, :confidence, :summary)

    FIXES = %w[add_index use_includes cache batch rewrite none].freeze
    ACTIONS = %w[promote none].freeze
    SEVERITIES = %w[low medium high].freeze
    CONFIDENCES = %w[low medium high].freeze

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un assistente di triage per le performance. Ricevi i dati aggregati di un gruppo-metrica
      (query lenta, metodo lento o problema di performance come N+1). Rispondi con:
      - category: categoria breve (es. "N+1", "full table scan", "metodo lento", "HTTP esterno lento").
      - severity: low, medium o high.
      - root_cause: causa più probabile in 1-2 frasi.
      - suggested_fix: una tra add_index, use_includes, cache, batch, rewrite, none.
      - suggested_action: promote (vale un ticket) oppure none (servono più dati).
      - confidence: low, medium o high.
      - summary: 1-2 frasi che spiegano il verdetto a uno sviluppatore.
      Rispondi in italiano.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    private

    def system_prompt = SYSTEM_PROMPT

    def user_context
      kind = @group.subtype.present? ? "#{@group.kind} / #{@group.subtype}" : @group.kind
      [
        "Progetto: #{@group.project.name}",
        "Tipo: #{kind}",
        "Signature: #{@group.title}",
        "Durata media: #{@group.average_duration_ms.round} ms " \
          "(min #{@group.duration_min_ms&.round} · max #{@group.duration_max_ms&.round})",
        "Campioni: #{@group.samples_count}",
        "Primo visto: #{@group.first_seen_at&.iso8601} · Ultimo: #{@group.last_seen_at&.iso8601}"
      ].join("\n")
    end

    def schema
      {
        type: "object",
        properties: {
          category: { type: "string", description: "Categoria breve" },
          severity: { type: "string", enum: SEVERITIES, description: "Severità" },
          root_cause: { type: "string", description: "Causa più probabile" },
          suggested_fix: { type: "string", enum: FIXES, description: "Fix tecnico suggerito" },
          suggested_action: { type: "string", enum: ACTIONS, description: "Azione consigliata" },
          confidence: { type: "string", enum: CONFIDENCES, description: "Confidenza del verdetto" },
          summary: { type: "string", description: "Spiegazione breve" }
        },
        required: %w[category suggested_fix suggested_action confidence summary]
      }
    end

    def build_triage(args)
      Triage.new(
        category: clean(args["category"]),
        severity: pick(args["severity"], SEVERITIES),
        root_cause: clean(args["root_cause"]),
        suggested_fix: pick(args["suggested_fix"], FIXES) || "none",
        suggested_action: pick(args["suggested_action"], ACTIONS) || "none",
        confidence: pick(args["confidence"], CONFIDENCES) || "low",
        summary: clean(args["summary"])
      )
    end
  end
end
