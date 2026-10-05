# frozen_string_literal: true

module Ideas
  # Transizioni di stato manuali dell'idea: open → archived (accantona) e archived → open
  # (riapre). `converted` è TERMINALE e si raggiunge solo via Ideas::PromoteToTicket.
  class ChangeStatus < ApplicationService
    TRANSITIONS = {
      "archived" => "open",   # verso archived si parte da open
      "open" => "archived"    # verso open si parte da archived (riapertura)
    }.freeze

    def initialize(idea:, to:, actor: nil, true_actor: nil)
      @idea = idea
      @to = to.to_s
      @actor = actor
      @true_actor = true_actor
    end

    def call
      return already_converted if @idea.status_converted?
      return invalid_transition unless TRANSITIONS[@to] == @idea.status

      # Mutazione di stato registrata come 'updated' (riusa ACTIONS esistenti, niente enum dedicato).
      ApplicationRecord.transaction do
        @idea.update!(status: @to)
        Activity::Record.call(subject: @idea, action: "updated", data: { fields: [ "status" ] },
                              actor: @actor, true_actor: @true_actor)
      end
      Result.ok(@idea)
    end

    private

    def already_converted
      Result.err(AppError.new(I18n.t("ideas.errors.already_converted"), code: "R422-IDEA-003"))
    end

    def invalid_transition
      Result.err(AppError.new(I18n.t("ideas.errors.invalid_transition"), code: "R422-IDEA-002"))
    end
  end
end
