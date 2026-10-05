# frozen_string_literal: true

module Observability
  # Base condivisa della promozione di un gruppo di monitoring a ticket, riusando Ticketing::CreateTicket:
  # le validazioni del ticket restano load-bearing, collega group.ticket, reporter = chi promuove (UI
  # Member). Idempotente sul già-promosso. Le sottoclassi forniscono il codice errore del proprio
  # dominio e i parametri del ticket (mappatura su UNO scenario BDD + dettagli tecnici in
  # technical_analysis).
  class PromoteToTicket < ApplicationService
    def initialize(group:, reporter:, true_actor: nil)
      @group = group
      @reporter = reporter
      @true_actor = true_actor
    end

    # Idempotente sotto concorrenza (CYRA-47): il check pre-lock scorcia il caso già-promosso senza
    # aprire una transazione; il with_lock serializza le richieste concorrenti (doppio click / retry di
    # rete) e il re-check dopo il lock (row ricaricata FOR UPDATE) garantisce doppio submit = 1 ticket.
    def call
      return already_promoted if @group.promoted?

      @group.with_lock do
        next already_promoted if @group.promoted?

        result = Ticketing::CreateTicket.call(
          organization: organization, reporter: @reporter, true_actor: @true_actor, params: ticket_params
        )
        @group.update!(ticket: result.value) if result.ok?
        result
      end
    end

    private

    def organization = @group.project.organization

    def already_promoted
      Result.err(AppError.new("Gruppo già promosso a ticket", code: already_promoted_code))
    end

    def default_status
      organization.ticket_statuses.find_by(code: "open") ||
        organization.ticket_statuses.active.ordered.first
    end

    def default_priority
      organization.ticket_priorities.find_by(code: "high") ||
        organization.ticket_priorities.active.ordered.first
    end

    def already_promoted_code = raise NotImplementedError, "#{self.class} deve definire already_promoted_code"
    def ticket_params = raise NotImplementedError, "#{self.class} deve definire ticket_params"
  end
end
