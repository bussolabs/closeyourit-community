# frozen_string_literal: true

module Cli
  module V1
    module Vulnerabilities
      # Promozione a ticket come risorsa singleton: PUT apre il ticket. Gate vulnerabilities.triage,
      # la stessa chiave del Member (aprire un ticket è smistare, non distruggere).
      #
      # A mano si promuove QUALSIASI riga: l'automatismo scatta solo su high/critical perché deve
      # sbagliare per difetto, ma chi guarda sa se quella moderate lo riguarda davvero.
      #
      # Il service è idempotente sotto concorrenza (già promossa → R422-VULN-001): il doppio submit
      # dà un ticket solo. Risponde col ticket creato, come la promozione degli error group.
      class PromotionsController < Cli::V1::BaseController
        before_action :set_finding!
        before_action -> { require_permission!("vulnerabilities.triage", scope: @finding.project) }

        def update
          result = ::Vulnerabilities::PromoteToTicket.call(group: @finding, reporter: Current.account)
          return render_created(TicketSerializer.new(result.value)) if result.ok?

          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end

        private

        # Anti-BOLA: lookup dentro i progetti visibili PRIMA del gate (invisibile → 404, non 403).
        def set_finding!
          @finding = ::Vulnerabilities::Finding
                     .where(project_id: visible_projects.select(:id))
                     .includes(:advisory, :project, package: :manifest)
                     .find(params[:vulnerability_id])
        end
      end
    end
  end
end
