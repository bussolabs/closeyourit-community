# frozen_string_literal: true

module Ideas
  # Elimina un case da un'idea APERTA: dopo conversione/archiviazione il contenuto è congelato.
  # Il gate autore-o-ideas.edit sta nel controller. Result pattern.
  class DeleteCase < ApplicationService
    def initialize(case_record:)
      @case_record = case_record
    end

    def call
      if @case_record.idea.locked?
        return Result.err(AppError.new(I18n.t("ideas.errors.locked"), code: "R422-IDEA-002"))
      end

      @case_record.destroy!
      Result.ok(@case_record)
    end
  end
end
