# frozen_string_literal: true

module Member
  module Ai
    # Esito delle richieste AI asincrone (polling della UI dopo il 202 degli endpoint AI).
    # Scoping per ownership: un account legge SOLO le proprie richieste (anti-BOLA 404).
    class RequestsController < Member::BaseController
      permission_not_required "Esito di una richiesta AI propria: lo scope per account e organizzazione è anche il " \
                              "confine (id altrui → 404)."

      def show
        request_record = ::Ai::Request.for(account: Current.account, organization: Current.organization)
                                      .find_by(id: params[:id])
        if request_record.nil?
          return render json: { error: { code: "R404-AI-001", message: t("member.ai.errors.not_found") } },
                        status: :not_found
        end

        render json: { data: body_for(request_record) }
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
