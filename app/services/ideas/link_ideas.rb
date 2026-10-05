# frozen_string_literal: true

module Ideas
  # Collega un'idea a un'altra dello stesso progetto (CYRA-845): `related` (parenti alla pari) o
  # `evolution` (l'idea passata evolve la target). L'idea arriva già scoped dal controller; la target
  # si risolve DENTRO il suo progetto (anti-BOLA: un id di un altro progetto/org → 404, mai leak).
  # Nessun congelamento: collegare un'idea convertita come base di un'evoluzione è il caso normale
  # (si evolve ciò che esiste). Result pattern.
  class LinkIdeas < ApplicationService
    def initialize(idea:, target_id:, kind: :related)
      @idea = idea
      @target_id = target_id
      @kind = kind
    end

    def call
      target = @idea.project.ideas.find_by(id: @target_id)
      return Result.err(AppError.new(I18n.t("ideas.errors.base_not_found"), code: "R404-IDEA-002", status: :not_found)) if target.nil?

      link = Ideas::Link.new(source: @idea, target: target, kind: @kind)
      return Result.ok(link) if link.save

      Result.err(AppError.new(I18n.t("ideas.errors.link_invalid"),
                              code: "R422-IDEA-006", details: link.errors.to_hash))
    rescue ArgumentError
      # kind fuori enum (payload CLI arbitrario): 422 pulito, non un 500.
      Result.err(AppError.new(I18n.t("ideas.errors.link_invalid"), code: "R422-IDEA-006",
                              details: { kind: [ "invalid" ] }))
    end
  end
end
