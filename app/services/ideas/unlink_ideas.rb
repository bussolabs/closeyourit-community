# frozen_string_literal: true

module Ideas
  # Toglie un collegamento fra due idee (CYRA-845), da qualunque lato lo si guardi: la riga è una
  # sola per coppia, quindi si cerca nei due versi. Il gate autore-o-ideas.edit sta nel controller.
  # Result pattern; coppia non collegata → 404.
  class UnlinkIdeas < ApplicationService
    def initialize(idea:, other_id:)
      @idea = idea
      @other_id = other_id
    end

    def call
      link = Ideas::Link.between(@idea.id, @other_id).first
      return Result.err(AppError.new(I18n.t("ideas.errors.base_not_found"), code: "R404-IDEA-002", status: :not_found)) if link.nil?

      link.destroy!
      Result.ok(link)
    end
  end
end
