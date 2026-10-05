# frozen_string_literal: true

module Knowledge
  module Review
    # Il verdetto del revisore: cosa ha riconosciuto e cosa ha trovato. Immutabile; le violazioni sono
    # Array<Violation>. `model` è il modello che ha giudicato davvero (dal chunk finale dello
    # stream), non l'alias chiesto.
    Verdict = Data.define(:format, :verdict, :violations, :suggested_kind, :suggested_title, :split_suggestion, :duplicate_of, :model) do
      def accepted? = verdict == "accept"
      def rejected? = !accepted?
      def blocking_violations = violations.select(&:blocking)

      # La forma per `AppError#details`: la CLI la mostra in `--json`, il form web la elenca.
      def to_details
        {
          format: format,
          violations: violations.map(&:to_h),
          suggested_kind: suggested_kind,
          suggested_title: suggested_title,
          split_suggestion: split_suggestion,
          duplicate_of: duplicate_of
        }
      end

      # Le colonne `ai_review_*` di Knowledge::Page.
      def page_attributes(reviewed_at: Time.current)
        {
          ai_review_format: format,
          ai_review_verdict: accepted? ? :accepted : :rejected,
          ai_review_violations: violations.map(&:to_h),
          ai_reviewed_at: reviewed_at,
          ai_review_model: model
        }
      end

      # Le prime violazioni, in una riga: è ciò che la CLI stampa (`code: message`, più il passaggio
      # citato quando c'è).
      def summary(limit: Knowledge::Constants::REVIEW_VIOLATIONS_IN_MESSAGE)
        violations.first(limit).map(&:to_line).join(" · ")
      end
    end
  end
end
