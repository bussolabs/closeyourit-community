# frozen_string_literal: true

module Servers
  module Actions
    class Complete < ApplicationService
      def initialize(action:, status:, exit_code: nil, output: nil, error: nil, result: {})
        @action, @status, @exit_code = action, status.to_s, exit_code
        @output, @error, @result = output.to_s.truncate(Servers::Action::OUTPUT_MAX),
                                           error.to_s.truncate(Servers::Action::OUTPUT_MAX), result || {}
      end

      def call
        return Result.ok(@action) if @action.status_succeeded? || @action.status_failed?
        # CYRA-809 — l'esito tardivo: l'azione era stata dichiarata interrotta (lease e autorizzazione
        # scadute senza notizie) e il server torna a dire com'è andata. Si accetta, ed è la ragione per
        # cui `interrupted` non è un esito definitivo: il posto era già libero, qui si sostituisce un
        # punto interrogativo con un fatto.
        unless %w[succeeded failed].include?(@status) && (@action.status_running? || @action.status_interrupted?)
          return Result.err(AppError.new("Transizione azione non valida", code: "R422-SERVER-006"))
        end

        @action.update!(status: @status, exit_code: @exit_code, output: @output.presence,
                        error: @error.presence, result: @result, finished_at: Time.current,
                        lease_expires_at: nil)
        # L'esito è il pezzo che spiega tutto (es. "nessun aggiornamento di sicurezza da installare"):
        # va a schermo appena arriva, non al prossimo push dell'agent.
        Servers::Broadcast.refresh(@action.host)
        Result.ok(@action)
      end
    end
  end
end
