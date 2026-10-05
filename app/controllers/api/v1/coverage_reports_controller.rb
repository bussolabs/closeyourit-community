# frozen_string_literal: true

module Api
  module V1
    # CYSK-26 — il canale d'ingresso dell'estratto di copertura: la CI lo pubblica dal branch di
    # default (POST, scope ingest, upsert per [project, branch]), chi analizza lo rilegge (GET, scope
    # read). Vive l'ULTIMA fotografia per branch, mai lo storico: la domanda a cui risponde è «di
    # questa misura ci si può fidare?», e per quella serve il presente, non la serie.
    class CoverageReportsController < Api::V1::BaseController
      before_action -> { require_scope!(:read) }, only: :index
      before_action -> { require_scope!(:ingest) }, only: :create

      def index
        # CYRA-738 — stessa domanda ai dati del canale CLI (Projects::CoverageReports::Query).
        reports = ::Projects::CoverageReports::Query.call(project: Current.project, branch: params[:branch])
        render_ok(CoverageReportSerializer.new(reports))
      end

      def create
        branch = params[:branch].to_s.strip
        return render_error("R422-COVERAGE-001", "branch obbligatorio", status: :unprocessable_content) if branch.blank?

        captured_at = parse_time(params[:captured_at]) || Time.current
        report = Current.project.coverage_reports.find_or_initialize_by(branch: branch)
        report.assign_attributes(
          sha: params[:sha].presence || report.sha,
          captured_at: captured_at,
          line_covered_percent: decimal_or_nil(params[:line_covered_percent]),
          branch_covered_percent: decimal_or_nil(params[:branch_covered_percent]),
          files_count: params[:files_count].to_i,
          never_loaded_count: params[:never_loaded_count].to_i,
          payload: payload_param
        )
        if report.save
          render json: { data: CoverageReportSerializer.new(report).as_json }, status: :created
        else
          render_error("R422-COVERAGE-002", report.errors.full_messages.to_sentence, status: :unprocessable_content)
        end
      rescue ActiveRecord::RecordNotUnique
        # Race di creazione concorrente: al secondo giro la riga esiste → update. Un solo retry.
        if (retried = !retried)
          retry
        else
          raise
        end
      end

      private

      # L'estratto viaggia com'è: la forma la valida chi la consuma, qui si tiene solo il tetto di
      # peso (nel modello). `permit!` su una copia isolata: non tocca gli altri parametri.
      def payload_param
        raw = params[:payload]
        raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : (raw.is_a?(Hash) ? raw : {})
      end

      def decimal_or_nil(raw)
        raw.present? ? raw.to_f : nil
      end

      def parse_time(raw)
        Time.iso8601(raw.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
