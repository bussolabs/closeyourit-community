# frozen_string_literal: true

module Ideas
  # Elimina un commento da un'idea APERTA: dopo conversione/archiviazione la discussione è
  # congelata anche in cancellazione (è la fonte della sintesi AI del ticket). Il gate
  # autore-o-ideas.comment.delete_any sta nel controller. Result pattern.
  class DeleteComment < ApplicationService
    def initialize(comment:)
      @comment = comment
    end

    def call
      return Result.err(AppError.new(I18n.t("ideas.errors.locked"), code: "R422-IDEA-002")) if @comment.idea.locked?

      @comment.destroy!
      Result.ok(@comment)
    end
  end
end
