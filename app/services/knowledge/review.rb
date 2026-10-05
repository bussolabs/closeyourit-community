# frozen_string_literal: true

module Knowledge
  # Revisore automatico delle pagine di conoscenza (CYRA-764): il pre-check deterministico
  # (Review::Precheck), le regole per il modello (Review::Rules), il verdetto (Review::Verdict) e il
  # suo parser (Review::Parse). L'orchestratore è Knowledge::ReviewPage.
  module Review
    REJECTED_CODE = "R422-KNOWLEDGE-013"

    # L'errore con cui i service si fermano su un verdetto negativo: il messaggio porta le prime
    # violazioni (la CLI stampa solo quello), i details l'elenco intero e il formato riconosciuto.
    def self.rejection(verdict)
      Result.err(AppError.new(I18n.t("member.knowledge.errors.quality_rejected", violations: verdict.summary),
                              code: REJECTED_CODE, status: :unprocessable_content, details: verdict.to_details))
    end

    # Le colonne da scrivere sulla pagina. Con il revisore spento (verdetto nil) si AZZERANO: il testo
    # è cambiato e il verdetto di prima parlava di un altro testo.
    def self.page_attributes(verdict)
      return verdict.page_attributes if verdict

      { ai_review_format: nil, ai_review_verdict: nil, ai_review_violations: [], ai_reviewed_at: nil, ai_review_model: nil }
    end

    # Lo scope che il revisore può nominare quando scrive una PERSONA: le pagine che vede, pubblicate
    # o in revisione.
    def self.scope_for(account:, organization:)
      Knowledge::Page.visible_to(account:, organization:, status: %i[published in_review])
    end

    # Lo scope senza attore (giro di riclassificazione): le pagine che condividono un progetto con
    # questa; una pagina org-wide (nessun progetto) vede solo le altre org-wide.
    def self.scope_around(page)
      base = Knowledge::Page.where(organization_id: page.organization_id, status: %i[published in_review])
      ids = page.project_ids
      return base.for_projects(ids) if ids.any?

      base.where.missing(:projects)
    end

    # Lo schema JSON che il modello deve rispettare. `additionalProperties: false` ovunque: un campo
    # inventato dal modello è un segnale che ha letto male le regole, non un'estensione.
    SCHEMA = {
      type: "object",
      additionalProperties: false,
      properties: {
        format: { type: "string", enum: Knowledge::Constants::REVIEW_FORMATS + [ "unknown" ] },
        verdict: { type: "string", enum: %w[accept reject] },
        violations: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            properties: { code: { type: "string" }, message: { type: "string" }, quote: { type: "string" } },
            # `quote` è obbligatoria ma può essere vuota (CYAU-200): una regola su qualcosa che manca
            # non ha un passaggio da citare, e un campo facoltativo il modello lo salta sempre.
            required: %w[code message quote]
          }
        },
        suggested_kind: { type: "string", enum: Knowledge::Page.kinds.keys },
        suggested_title: { type: "string" },
        split_suggestion: { type: "array", items: { type: "string" } },
        duplicate_of: { type: [ "string", "null" ] }
      },
      required: %w[format verdict violations suggested_kind suggested_title]
    }.freeze
  end
end
