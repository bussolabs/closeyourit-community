# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Cronologia del resoconto di lavorazione (CYRA-220): sola lettura, risolta per NUMERO di
      # versione e non per UUID — il numero è unico per ticket, stabile e leggibile in un comando.
      class ReportVersionsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def index
          versions, meta = paginate(@ticket.reports.reorder(version: :desc).includes(:author))
          render_ok(ReportSerializer.new(versions), meta: meta)
        end

        def show
          render_ok(ReportSerializer.new(@ticket.reports.find_by!(version: params[:id])))
        end

        private

        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end
      end
    end
  end
end
