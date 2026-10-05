# frozen_string_literal: true

module Knowledge
  # Giudica UNA pagina già esistente con il revisore automatico (CYRA-764) e ne registra il verdetto.
  # Serve al giro di riclassificazione del parco: i salvataggi normali sono sincroni dentro
  # CreatePage/UpdatePage/Publish e non passano di qui.
  #
  # Una pagina PUBBLICATA che non passa torna in revisione: esce da ricerca e risposte finché una
  # persona non la corregge o la scarta. `reviewed_by`/`reviewed_at` restano com'erano — sono la
  # traccia della prima accettazione umana; le violazioni stanno in `ai_review_violations`, che la
  # coda mostra, e nella `review_note` solo se era vuota (è la riga che si legge in coda).
  # Con `dry_run: true` si scrive SOLO il verdetto: serve a contare quante cadrebbero prima del giro vero.
  class ReviewPageJob < ApplicationJob
    queue_as :knowledge_review

    # Attesa in minuti con jitter: il server di casa che non risponde non torna in dieci secondi.
    # TransientFailure e non AppError (CYRA-713): una chiave rifiutata è definitiva e non si riprova.
    retry_on TransientFailure,
             wait: ->(executions) { (executions**2).minutes + rand(0..59).seconds },
             attempts: MAX_ATTEMPTS = 6 do |job, error|
      Rails.logger.warn("[knowledge-review] abbandonata #{job.arguments.first[:page_id]}: #{error.try(:code) || error.class}")
    end

    def perform(page_id:, force: false, dry_run: false, legacy: false)
      page = Knowledge::Page.find_by(id: page_id)
      return if page.nil? || page.status_rejected?
      Current.organization = page.organization # runs with this organization's AI settings (CYRA-914)
      # Già giudicata su questo testo: un rilancio costa una SELECT, non una chiamata al modello. Se
      # il verdetto era negativo ma la pagina è ancora pubblicata — il dry_run l'ha lasciata così —
      # il giro reale la retrocede con il verdetto che ha già, senza rigiudicarla.
      if !force && page.ai_reviewed_at.present? && page.ai_reviewed_at >= page.updated_at
        demote(page) if !dry_run && page.ai_review_rejected? && page.status_published?
        return
      end
      # Il god ha tirato il freno a metà giro: fermarsi. Spegnere deve voler dire «smetti».
      return if Ai::Feature.disabled?(:knowledge_review)

      seen_at = page.updated_at
      result = Knowledge::ReviewPage.call(title: page.title, body: page.body, tech_spec: page.tech_spec, kind: page.kind,
                                          tags: page.tags, scope: Knowledge::Review.scope_around(page), exclude_page_id: page.id,
                                          legacy:)
      return abandon(page, result.error) if result.err? && definitive?(result.error)
      raise result.error if result.err?

      verdict = result.value
      return if verdict.nil?

      # Fra la chiamata (decine di secondi) e adesso una persona può aver riscritto o scartato la
      # pagina: un verdetto sul testo di prima non si scrive, e una scartata non si risuscita.
      page.reload
      return if page.status_rejected? || page.updated_at != seen_at

      apply(page, verdict, dry_run:)
      # Modalità legacy (CYRA-773): la pagina promossa riceve da sola riga del formato e tag. Nel
      # dry_run no: il conteggio non scrive niente oltre al verdetto.
      Knowledge::Review::Normalize.call(page:, format: verdict.format) if legacy && verdict.accepted? && !dry_run
    end

    private

    # Il 503 del revisore avvolge anche cause DEFINITIVE — chiave rifiutata, alias sconosciuto, ENV
    # assenti — che un retry ripeterebbe sei volte con lo stesso esito. La causa sta nei details.
    def definitive?(error)
      cause = error.details.to_h[:cause].to_s
      cause == "unconfigured" || TransientFailure::DEFINITIVE_CODES.include?(cause)
    end

    def abandon(page, error)
      Rails.logger.warn("[knowledge-review] abbandonata #{page.id} senza ritentare: #{error.details.to_h[:cause]}")
    end

    def apply(page, verdict, dry_run:)
      # update_columns: il testo non cambia, quindi niente versione, niente re-embed, niente
      # callback che rivaluti il linguaggio semplice.
      page.update_columns(verdict.page_attributes) # rubocop:disable Rails/SkipsModelValidations
      demote(page) if verdict.rejected? && !dry_run && page.status_published?
    end

    # La retrocessione legge il verdetto DALLE COLONNE, così vale sia appena giudicata sia al giro
    # reale dopo un dry_run. `updated_at` uguale ad `ai_reviewed_at`: retrocedere non è modificare
    # il testo, e un rilancio non deve rigiudicare.
    def demote(page)
      codes = page.ai_review_violations.map { |v| v["code"] }
      ApplicationRecord.transaction do
        page.update!(status: :in_review, updated_at: page.ai_reviewed_at,
                     review_note: page.review_note.presence || demotion_note(page))
      end
      Rails.logger.info("[knowledge-review] rimandata in revisione #{page.id}: #{codes.join(', ')}")
    end

    def demotion_note(page)
      summary = page.ai_review_violations.first(Knowledge::Constants::REVIEW_VIOLATIONS_IN_MESSAGE)
                    .map { |v| "#{v['code']} — #{v['message']}" }.join(" · ")
      I18n.t("member.knowledge.review.demoted_note", violations: summary).truncate(Knowledge::Constants::REVIEW_NOTE_MAX_CHARS)
    end
  end
end
