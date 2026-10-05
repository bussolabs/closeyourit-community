# frozen_string_literal: true

module Cli
  module V1
    module Seo
      # Promozione a ticket come risorsa singleton: PUT apre il ticket. Gate seo.triage, la stessa
      # chiave del Member (aprire un ticket è smistare, non distruggere).
      #
      # A mano si promuove QUALSIASI rilievo, anche uno minore: l'avviso automatico si limita ai
      # gravi perché deve sbagliare per difetto, ma chi guarda sa se quella riga lo riguarda.
      #
      # Il service è idempotente sotto concorrenza (già promosso → R422-SEO-001): il doppio submit dà
      # un ticket solo.
      class PromotionsController < Cli::V1::BaseController
        before_action :set_issue!
        before_action -> { require_permission!("seo.triage", scope: @issue.site.project) }

        def update
          result = ::Seo::PromoteToTicket.call(issue: @issue, reporter: Current.account)
          return render_created(TicketSerializer.new(result.value)) if result.ok?

          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end

        private

        # Anti-BOLA: lookup dentro i progetti visibili PRIMA del gate (invisibile → 404, non 403).
        def set_issue!
          sites = ::Seo::Site.where(project_id: visible_projects.select(:id))
          @issue = ::Seo::Issue.where(site_id: sites.select(:id))
                               .includes(:page, site: %i[project environment])
                               .find(params[:seo_id])
        end
      end
    end
  end
end
