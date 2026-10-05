# frozen_string_literal: true

module Knowledge
  module Review
    # Da Hash del modello a Verdict. Fail-closed su ogni incoerenza: un verdetto fuori enum è
    # illeggibile (R502-KNOWLEDGE-001, la pagina non entra), un `accept` con formato `unknown` o con
    # violazioni è un `reject` — il modello ha detto due cose insieme e vale quella prudente.
    class Parse < ApplicationService
      ERROR_CODE = "R502-KNOWLEDGE-001"

      # `source` è il testo della pagina (corpo + parte tecnica): serve a verificare che il passaggio
      # citato dal modello ci sia davvero. Senza (nessun chiamante in app) la citazione si tiene
      # com'è: non c'è niente con cui confrontarla.
      def initialize(payload:, model: nil, precheck_violations: [], source: nil)
        @payload = payload
        @model = model
        @precheck_violations = precheck_violations
        @source = source
      end

      def call
        return unreadable("non è un oggetto") unless @payload.is_a?(Hash)

        format = @payload["format"].to_s
        verdict = @payload["verdict"].to_s
        return unreadable("format «#{format}»") unless (Knowledge::Constants::REVIEW_FORMATS + [ "unknown" ]).include?(format)
        return unreadable("verdict «#{verdict}»") unless %w[accept reject].include?(verdict)

        from_model = model_violations
        return unreadable("violazioni malformate") if from_model.nil?

        violations = @precheck_violations + from_model

        # Il verdetto lo decidono le violazioni BLOCCANTI, non la parola del modello: con soli avvisi
        # (regole meccaniche che cita lo stesso) la pagina passa, anche se lui ha scritto «reject».
        verdict = (format == "unknown" || violations.any?(&:blocking)) ? "reject" : "accept"
        # Un rifiuto deve dire PERCHÉ: «formato non riconosciuto» senza una riga sarebbe un messaggio vuoto.
        violations << Violation.new(code: "K00", message: I18n.t("member.knowledge.review_rules.K00")) if format == "unknown" && violations.none?

        Result.ok(Verdict.new(
          format: format, verdict: verdict, violations: violations,
          suggested_kind: pick(@payload["suggested_kind"], Knowledge::Page.kinds.keys),
          suggested_title: @payload["suggested_title"].to_s.strip.first(255).presence,
          split_suggestion: Array(@payload["split_suggestion"]).map(&:to_s).reject(&:blank?),
          duplicate_of: @payload["duplicate_of"].to_s.strip.presence,
          model: @model
        ))
      end

      private

      def model_violations
        # Campo obbligatorio dello schema: assente vuol dire che il modello non l'ha rispettato, e
        # un accept senza elenco non è un accept (fail-closed).
        raw = @payload["violations"]
        return nil unless raw.is_a?(Array)

        raw.map do |item|
          return nil unless item.is_a?(Hash) && item["code"].present? && item["message"].present?

          code = item["code"].to_s.strip.first(16)
          Violation.new(code: code, message: item["message"].to_s.strip.first(500),
                        blocking: !mechanical?(code), quote: quote_from(item["quote"]))
        end
      end

      # Il passaggio che motiva la violazione (CYAU-200). Si tiene solo se compare DAVVERO nella
      # pagina: una citazione inventata manda a cercare una frase che nessuno ha scritto, e chi
      # corregge perde più tempo che senza. Vuota quando la regola riguarda qualcosa che manca.
      def quote_from(raw)
        quote = raw.to_s.strip.first(Knowledge::Constants::REVIEW_QUOTE_MAX_CHARS)
        return nil if quote.blank?
        return quote if @source.nil? || flatten(@source).include?(flatten(quote))

        Rails.logger.warn("[knowledge-review] citazione fuori dal testo: scartata (#{quote.length} caratteri)")
        nil
      end

      # Il modello ricopia il passaggio a memoria: spazi e a capo cambiano, le parole no.
      def flatten(text) = text.to_s.gsub(/\s+/, " ").strip.downcase

      # Le regole meccaniche (riga Formato, forma del titolo, kind, tag, lunghezze, wikilink) le
      # decide il pre-check in Ruby, che è deterministico. Quando il modello le cita — e le cita
      # anche quando sono a posto: ha rifiutato titoli che lui stesso aveva suggerito (CYRA-773) —
      # restano un avviso: il rifiuto del modello vale solo sulla sostanza.
      MECHANICAL = /\A(K01|K02|K10|K11|K12|K14)(\b|_)/

      def mechanical?(code) = code.match?(MECHANICAL)

      def pick(value, allowed) = allowed.include?(value.to_s) ? value.to_s : nil

      def unreadable(why)
        Rails.logger.error("[knowledge-review] verdetto illeggibile: #{why}")
        Result.err(AppError.new(I18n.t("member.knowledge.errors.review_unreadable"), code: ERROR_CODE, status: :bad_gateway))
      end
    end
  end
end
