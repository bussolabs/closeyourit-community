# frozen_string_literal: true

module Ideas
  # Aggiunge un case a un'idea APERTA: il contenuto dell'idea si congela alla conversione o
  # all'archiviazione (come i commenti). Result pattern.
  class AddCase < ApplicationService
    def initialize(idea:, params:)
      @idea = idea
      @params = params
    end

    def call
      return Result.err(AppError.new(I18n.t("ideas.errors.locked"), code: "R422-IDEA-002")) if @idea.locked?

      case_record = @idea.cases.new(title: @params[:title], description: @params[:description])
      return Result.ok(case_record) if case_record.save

      Result.err(AppError.new(I18n.t("ideas.errors.case_invalid"),
                              code: "R422-IDEA-005", details: case_record.errors.to_hash))
    end
  end
end
