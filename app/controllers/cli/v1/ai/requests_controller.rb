# frozen_string_literal: true

module Cli
  module V1
    module Ai
      # Esito delle richieste AI asincrone dal terminale: il polling dopo il 202 di
      # POST /cli/v1/tickets/ask. Gemello di Member::Ai::RequestsController, che finora era l'unico
      # posto da cui si potesse leggere l'esito — e stava dentro il sito.
      #
      # Scoping per ownership: un account legge SOLO le proprie richieste, e una richiesta altrui
      # non si distingue da una che non esiste (404, mai 403).
      class RequestsController < Cli::V1::BaseController
        def show
          request_record = ::Ai::Request.for(account: Current.account, organization: Current.organization)
                                        .find_by(id: params[:id])
          return render_error("R404-AI-001", I18n.t("member.ai.errors.not_found"), status: :not_found) if request_record.nil?

          render_ok(body_for(request_record))
        end

        private

        def body_for(request_record)
          case request_record.status.to_sym
          when :pending then { status: "pending" }
          when :done    then { status: "done", result: request_record.payload }
          else { status: "failed",
                 error: { code: request_record.error_code, message: request_record.error_message } }
          end
        end
      end
    end
  end
end
