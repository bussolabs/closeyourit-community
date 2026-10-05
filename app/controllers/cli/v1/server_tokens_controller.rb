# frozen_string_literal: true

module Cli
  module V1
    # Enrollment token della flotta (universali org-scoped, consumati dagli agent). Tutto gated da
    # servers.manage. Il create ritorna il SEGRETO una sola volta (reveal-once) accanto al record;
    # in DB e nelle letture successive esiste solo il prefix. destroy = revoca soft (idempotente).
    class ServerTokensController < Cli::V1::BaseController
      before_action :require_manage

      def index
        records, meta = paginate(Current.organization.server_enrollment_tokens
                                                     .order(revoked_at: :asc, created_at: :desc))
        render_ok(EnrollmentTokenSerializer.new(records), meta: meta)
      end

      def create
        result = ::Servers::EnrollmentTokens::Issue.call(
          organization: Current.organization, name: params[:name], created_by: Current.account
        )
        if result.ok?
          payload = EnrollmentTokenSerializer.new(result.value[:token]).as_json
          render json: { data: payload.merge("secret" => result.value[:secret]) }, status: :created
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def destroy
        token = Current.organization.server_enrollment_tokens.find(params[:id])
        ::Servers::EnrollmentTokens::Revoke.call(token: token)
        render_no_content
      end

      private

      def require_manage
        require_permission!("servers.manage")
      end
    end
  end
end
