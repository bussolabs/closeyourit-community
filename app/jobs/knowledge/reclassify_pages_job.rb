# frozen_string_literal: true

module Knowledge
  # Riclassificazione del parco pagine con il revisore automatico (CYRA-764): accoda un
  # ReviewPageJob per ogni pagina pubblicata o in revisione, sulla corsia `knowledge_review`, una
  # alla volta. Giro una tantum, non ricorrente: si lancia a mano e si può rilanciare (le pagine
  # già giudicate sul testo corrente vengono saltate, salvo `force: true`).
  #
  #   bin/rails runner 'Knowledge::ReclassifyPagesJob.perform_later(dry_run: true)'   # conta
  #   bin/rails runner 'Knowledge::ReclassifyPagesJob.perform_later'                  # giro vero
  #
  # PRIMA il dry_run: scrive solo il verdetto, senza spostare nessuna pagina, e
  # `Knowledge::Page.ai_review_rejected.count` dice quante cadrebbero. Il giro vero rimanda in
  # revisione le pubblicate che non passano.
  class ReclassifyPagesJob < ApplicationJob
    queue_as :batch

    # `legacy: true` (CYRA-773): giudica il CONTENUTO ignorando le regole di sola forma e mette in
    # regola le promosse. Rigiudica anche le pagine già bocciate dal giro severo — quel verdetto
    # parlava di forma, non di sostanza — quindi vale come `force`.
    #
    #   bin/rails runner 'Knowledge::ReclassifyPagesJob.perform_later(legacy: true, dry_run: true)'
    #   bin/rails runner 'Knowledge::ReclassifyPagesJob.perform_later(legacy: true)'
    def perform(force: false, dry_run: false, legacy: false)
      force ||= legacy
      scope = Knowledge::Page.where(status: %i[published in_review])
      # Senza force: le mai giudicate, più le bocciate dal dry_run ancora pubblicate — il giro reale
      # le retrocede senza rigiudicarle (ReviewPageJob).
      scope = scope.where(ai_reviewed_at: nil).or(scope.ai_review_rejected) unless force
      count = 0
      scope.find_each do |page|
        Knowledge::ReviewPageJob.perform_later(page_id: page.id, force:, dry_run:, legacy:)
        count += 1
      end
      Rails.logger.info("[knowledge-review] riclassificazione accodata: #{count} pagine (force=#{force}, dry_run=#{dry_run}, legacy=#{legacy})")
    end
  end
end
