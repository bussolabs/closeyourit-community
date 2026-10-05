# frozen_string_literal: true

module Errors
  # Triage assistito AI di un gruppo errore: l'AI propone categoria, severità reale, causa probabile,
  # azione consigliata (resolve/ignore/promote/none), confidenza e un riassunto. Specializza
  # Observability::TriageWithAi. È SOLO un consiglio: l'umano applica con Errors::Triage /
  # Errors::PromoteToTicket. Output vincolato da uno schema (`response_schema`).
  class TriageWithAi < Observability::TriageWithAi
    Triage = Data.define(:category, :severity_suggested, :root_cause, :suggested_action, :confidence, :summary)

    ACTIONS = %w[resolve ignore promote none].freeze
    SEVERITIES = Errors::Group.levels.keys.freeze
    CONFIDENCES = %w[low medium high].freeze
    STACKTRACE_FRAME_LIMIT = 15

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un assistente di triage per un sistema di error monitoring. Ricevi i dati aggregati di un
      gruppo di errori (stesso fingerprint) più l'ultima occorrenza. Rispondi con:
      - category: categoria tecnica breve (es. "NULL dereference", "DB timeout", "rate limit", "validation").
      - severity_suggested: una tra debug, info, warning, error, fatal — quanto è grave davvero.
      - root_cause: causa più probabile in 1-2 frasi, basata su stacktrace e messaggio.
      - suggested_action: una tra resolve, ignore, promote, none.
        promote = vale un ticket da risolvere; resolve = sembra già rientrato/non riproducibile;
        ignore = rumore non azionabile; none = servono più dati.
      - confidence: low, medium o high.
      - summary: 1-2 frasi che spiegano il verdetto a uno sviluppatore.
      Rispondi in italiano.
      #{Text::ItalianOrthography::PROMPT_RULE}
    PROMPT

    private

    def system_prompt = SYSTEM_PROMPT

    def user_context
      latest = @group.events.order(occurred_at: :desc).first
      lines = [
        "Progetto: #{@group.project.name}",
        "Titolo: #{@group.title}",
        "Posizione (culprit): #{@group.culprit.presence || 'sconosciuta'}",
        "Livello attuale: #{@group.level}",
        "Occorrenze: #{@group.events_count} · Utenti colpiti: #{@group.users_count}",
        "Primo visto: #{@group.first_seen_at&.iso8601} · Ultimo: #{@group.last_seen_at&.iso8601}",
        "Release: #{@group.release.presence || 'n/d'}"
      ]
      lines << "Ambiente: #{latest.environment}" if latest&.environment.present?
      lines << "Stacktrace (frame in-app):\n#{format_stacktrace(latest)}" if latest
      lines.join("\n")
    end

    def format_stacktrace(event)
      # L'ingest persiste SEMPRE la forma Sentry {"frames" => [...]} (colonna jsonb, default {}). Nell'ordine
      # Sentry il frame del crash è l'ultimo: reverse per passare all'AI prima i frame più vicini al crash.
      frames = Array(event.stacktrace["frames"]).reverse.first(STACKTRACE_FRAME_LIMIT)
      return "n/d" if frames.blank?

      frames.map do |frame|
        next frame.to_s unless frame.is_a?(Hash)

        "#{frame['filename']}:#{frame['lineno']} in #{frame['function']}"
      end.join("\n")
    end

    def schema
      {
        type: "object",
        properties: {
          category: { type: "string", description: "Categoria tecnica breve" },
          severity_suggested: { type: "string", enum: SEVERITIES, description: "Severità reale (debug…fatal)" },
          root_cause: { type: "string", description: "Causa più probabile" },
          suggested_action: { type: "string", enum: ACTIONS, description: "Azione consigliata" },
          confidence: { type: "string", enum: CONFIDENCES, description: "Confidenza del verdetto" },
          summary: { type: "string", description: "Spiegazione breve" }
        },
        required: %w[category suggested_action confidence summary]
      }
    end

    def build_triage(args)
      Triage.new(
        category: clean(args["category"]),
        severity_suggested: pick(args["severity_suggested"], SEVERITIES),
        root_cause: clean(args["root_cause"]),
        suggested_action: pick(args["suggested_action"], ACTIONS) || "none",
        confidence: pick(args["confidence"], CONFIDENCES) || "low",
        summary: clean(args["summary"])
      )
    end
  end
end
