# frozen_string_literal: true

module Api
  module V1
    # Bootstrap di un'installazione Automator. La macchina si auto-registra col token del SUO service account
    # (cyi_u_): il server lega l'host a quel service account (Current.account) e conia il token host cyi_ah_
    # per pull/coda/heartbeat. Un token umano o d'organizzazione NON può registrare host.
    class HostsController < Api::BaseController
      include UserTokenAuthentication

      before_action :authenticate_user_token!
      before_action :require_service_account!

      def create
        result = ::Agents::Hosts::Register.call(
          organization: Current.organization,
          service_account: Current.account,
          **host_params.to_h.symbolize_keys
        )
        if result.ok?
          value = result.value
          data = AgentHostSerializer.new(value.fetch(:host)).as_json.merge(token: value.fetch(:secret))
          render json: { data: }, status: value.fetch(:created) ? :created : :ok
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      private

      # Solo un service account (l'identità di UNA macchina) registra un host: una sessione utente umana è
      # rifiutata, così un umano non può avviare né rilevare la registrazione di una macchina.
      def require_service_account!
        return if Current.account&.service?

        render_error("R403-AGENT-002", "Solo un service account può registrare un host", status: :forbidden)
      end

      def host_params
        params.permit(:fingerprint, :hostname, :platform, :arch, :automator_version)
      end
    end
  end
end
