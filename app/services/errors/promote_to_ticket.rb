# frozen_string_literal: true

module Errors
  # Promuove un gruppo d'errore a ticket: mappa l'errore su UNO scenario BDD (Given/When/Then/Expected)
  # e sposta i dettagli tecnici (env/release/server/runtime) in technical_analysis. Specializza
  # Observability::PromoteToTicket. reporter = chi promuove (UI Member).
  class PromoteToTicket < Observability::PromoteToTicket
    private

    def already_promoted_code = "R422-ERROR-001"

    def ticket_params
      event = @group.events.order(occurred_at: :desc).first
      {
        project_id: @group.project_id,
        # CYRA-399 — il titolo era il messaggio dell'eccezione così com'era: quattro righe di roba
        # tecnica in cima alla colonna più letta. Ora è una frase leggibile; il messaggio integrale
        # non si perde, sta nel corpo (`description`), che è dove si va a cercarlo.
        title: ::Errors::TicketTitle.call(group: @group),
        description: description_with_technical_message,
        technical_analysis: technical_details(event),
        scenarios_attributes: [ {
          step_given: "Reported from error monitoring.",
          step_when: @group.culprit.presence || "Unknown location",
          step_then: @group.title.presence || "An error occurred.",
          step_expected: "No exception should be raised."
        } ],
        status_id: default_status&.id,
        priority_id: default_priority&.id
      }
    end

    # Il messaggio originale dell'eccezione, verbatim, nel corpo del ticket: il titolo lo riassume,
    # ma chi apre il ticket per lavorarci deve poter leggere la riga esatta che è arrivata.
    def description_with_technical_message
      I18n.t("errors.promoted.description",
             message: ::Errors::TicketTitle.technical_line(@group),
             location: @group.culprit.presence || I18n.t("errors.promoted.unknown_location"))
    end

    # Dettagli tecnici dell'errore → technical_analysis (registro tecnico, fuori dal corpo human-simple).
    def technical_details(event)
      return nil if event.nil?

      parts = []
      parts << "Environment: #{event.environment}" if event.environment.present?
      parts << "Release: #{event.release}" if event.release.present?
      parts << "Server: #{event.server_name}" if event.server_name.present?
      parts << "Runtime: #{event.runtime}" if event.runtime.present?
      # I valori vengono dall'ingest (li manda il client, senza tetto): troncati al limite del campo
      # così un release o un server_name abnorme non fa fallire la promozione, che l'utente non
      # potrebbe comunque sbloccare — i dati dell'errore non sono modificabili a mano.
      parts.presence&.join("\n")&.truncate(Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS)
    end
  end
end
