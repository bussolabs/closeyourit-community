# frozen_string_literal: true

module Ideas
  # Modifica un case di un'idea APERTA (congelato dopo conversione/archiviazione). Il case arriva
  # già risolto e scoped dal controller. Result pattern.
  class UpdateCase < ApplicationService
    def initialize(case_record:, params:)
      @case_record = case_record
      @params = params
    end

    def call
      if @case_record.idea.locked?
        return Result.err(AppError.new(I18n.t("ideas.errors.locked"), code: "R422-IDEA-002"))
      end

      if @case_record.update(title: @params[:title], description: @params[:description])
        Result.ok(@case_record)
      else
        Result.err(AppError.new(I18n.t("ideas.errors.case_invalid"),
                                code: "R422-IDEA-005", details: @case_record.errors.to_hash))
      end
    end
  end
end
