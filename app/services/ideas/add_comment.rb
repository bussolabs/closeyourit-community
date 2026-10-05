# frozen_string_literal: true

module Ideas
  # Aggiunge un commento a un'idea APERTA (la discussione si congela alla conversione o
  # all'archiviazione). Menzioni/allegati restano fuori dalla v1 (differenza voluta rispetto a
  # Ticketing::AddComment); la notifica idea_commented è aggiunta in CYRA-147. Result pattern.
  class AddComment < ApplicationService
    def initialize(idea:, author:, params:)
      @idea = idea
      @author = author
      @params = params
    end

    def call
      return Result.err(AppError.new(I18n.t("ideas.errors.locked"), code: "R422-IDEA-002")) if @idea.locked?

      comment = @idea.comments.new(body: @params[:body], author: @author)
      if comment.save
        notify_commented(comment)
        return Result.ok(comment)
      end

      too_long?(comment) ? too_long_error(comment) : invalid_error(comment)
    end

    private

    # CYRA-147: avvisa chi vede il progetto dell'idea (autore del commento escluso via actor_id) riusando
    # la pipeline rule-based. Enqueue DOPO il save committato, su coda :alerts. Senza una regola
    # idea_commented attiva nell'org, Evaluate è un no-op.
    def notify_commented(comment)
      Alerting::EvaluateJob.perform_later(
        event_type: "idea_commented", subject_type: "Ideas::Comment", subject_id: comment.id,
        project_id: @idea.project_id, actor_id: @author&.id
      )
    end

    def too_long?(comment)
      comment.errors.details[:body].any? { |detail| detail[:error] == :length_budget_exceeded }
    end

    # Come sui ticket: il superamento del tetto merita un messaggio che dica QUANTO si è sforato,
    # non "commento non valido". Codice a sé perché un chiamante macchina deve poterlo distinguere.
    def too_long_error(comment)
      actual = comment.errors.details[:body].find { |d| d[:error] == :length_budget_exceeded }[:actual]
      Result.err(AppError.new(
                   I18n.t("ideas.errors.comment_too_long",
                          count: Ideas::Constants::COMMENT_MAX_CHARS, actual: actual),
                   code: "R422-IDEA-005", details: comment.errors.to_hash
                 ))
    end

    def invalid_error(comment)
      Result.err(AppError.new(I18n.t("ideas.errors.comment_invalid"),
                              code: "R422-IDEA-004", details: comment.errors.to_hash))
    end
  end
end
