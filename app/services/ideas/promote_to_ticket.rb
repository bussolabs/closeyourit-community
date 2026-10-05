# frozen_string_literal: true

module Ideas
  # Promuove un'idea APERTA a ticket riusando Ticketing::CreateTicket (le validazioni del ticket
  # restano load-bearing: serve sempre un corpo). Congela l'idea (status converted, terminale) e
  # salva il backlink. Idempotente sul
  # già-convertito. Pattern Errors::PromoteToTicket. reporter = chi converte.
  class PromoteToTicket < ApplicationService
    def initialize(idea:, reporter:, params:, true_actor: nil)
      @idea = idea
      @reporter = reporter
      @params = params
      @true_actor = true_actor
    end

    def call
      return already_converted if @idea.status_converted?
      return locked if @idea.locked?

      result = Ticketing::CreateTicket.call(
        organization: organization, reporter: @reporter, true_actor: @true_actor, params: ticket_params
      )
      @idea.update!(ticket: result.value, status: :converted, converted_at: Time.current) if result.ok?
      result
    end

    private

    def organization = @idea.project.organization

    def already_converted
      Result.err(AppError.new(I18n.t("ideas.errors.already_converted"), code: "R422-IDEA-003"))
    end

    def locked
      Result.err(AppError.new(I18n.t("ideas.errors.locked"), code: "R422-IDEA-002"))
    end

    def ticket_params
      {
        project_id: @idea.project_id,
        title: @params[:title].presence || @idea.title,
        description: @params[:description],
        kind: kind,
        status_id: @params[:status_id].presence || default_status&.id,
        priority_id: @params[:priority_id].presence || default_priority&.id
      }
    end

    # Default `story`: un'idea è una proposta di valore per chi usa il prodotto, non un guasto.
    def kind
      @params[:kind].presence || :story
    end

    def default_status
      organization.ticket_statuses.find_by(code: "open") ||
        organization.ticket_statuses.active.ordered.first
    end

    # Un'idea promossa non è un incidente: priorità default media (non "high" come gli errori).
    def default_priority
      organization.ticket_priorities.find_by(code: "medium") ||
        organization.ticket_priorities.active.ordered.first
    end
  end
end
