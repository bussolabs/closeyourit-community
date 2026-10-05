# frozen_string_literal: true

module Cli
  module V1
    module Tickets
      # Resoconto di lavorazione via CLI (CYRA-220). Leggere e scrivere sono baseline come i commenti:
      # chi vede il progetto (set_project! → visibilità Fase E) vede il ticket e può scrivere il
      # resoconto. La logica vive in Ticketing::RecordReport; qui solo l'adattamento HTTP.
      #
      # È un singleton: POST non sovrascrive, scrive la versione successiva. Non esiste update né
      # destroy — una versione è append-only.
      class ReportsController < Cli::V1::BaseController
        before_action :set_project!
        before_action :set_ticket

        def show
          report = current_report
          return render_error("R404-REPORT-001", I18n.t("ticketing.reports.errors.not_found"),
                              status: :not_found) if report.blank?

          render_ok(ReportSerializer.new(report))
        end

        def create
          result = Ticketing::RecordReport.call(ticket: @ticket, author: Current.account,
                                                body: params[:body], source: :agent)
          if result.ok?
            render_created(ReportSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        private

        # `reorder`: l'associazione ordina già per version ascendente e un secondo `order` ci si
        # accoderebbe invece di sostituirlo, restituendo la versione 1 come corrente.
        def current_report
          @ticket.reports.reorder(version: :desc).first
        end

        # Ticket dentro il progetto già scoped a visible_projects (set_project!): anti-BOLA, un ticket
        # fuori dalla visibilità → RecordNotFound → R404, mai 403. UUID o code umano.
        def set_ticket
          @ticket = find_ticket!(@project, params[:ticket_id])
        end
      end
    end
  end
end
