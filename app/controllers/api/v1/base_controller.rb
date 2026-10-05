# frozen_string_literal: true

module Api
  module V1
    # Base dell'API v1 a token bearer. Ogni richiesta autentica via token (pinna org+project su Current).
    class BaseController < Api::BaseController
      include TokenAuthentication

      before_action :authenticate_token!

      private

      # Paginazione offset → [records, meta] per l'envelope {data:, meta:} (mirror Cli::V1).
      # Evita di serializzare l'intera lista (DoS su progetti con decine di migliaia di gruppi).
      def paginate(scope)
        result = Pagination.call(scope, page: params[:page], per: params[:per].presence || Pagination::MACHINE_DEFAULT_PER)
        meta = { page: result.page, per: result.per, total: result.total, total_pages: result.total_pages }
        [ result.records, meta ]
      end
    end
  end
end
