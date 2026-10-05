# frozen_string_literal: true

module Api
  module V1
    # CYRA-871 — la CI segnala che il controllo dopo il deploy ha trovato la produzione giù o con la
    # versione sbagliata: nasce un ticket per il CTO, uno per versione (201 la prima volta, 200 dopo).
    class DeployFailuresController < Api::V1::BaseController
      before_action -> { require_scope!(:ingest) }

      def create
        version = params[:version].to_s.strip
        return render_error("R422-RELEASE-002", "version obbligatoria", status: :unprocessable_content) if version.blank?

        result = ::Projects::Releases::ReportDeployFailure.call(project: Current.project, version:,
                                                                reason: params[:reason], run_url: params[:run_url])
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

        render json: { data: { id: result.value.ticket.id, code: result.value.ticket.code } },
               status: result.value.created ? :created : :ok
      end
    end
  end
end
