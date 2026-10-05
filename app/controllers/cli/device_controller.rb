# frozen_string_literal: true

module Cli
  # Bootstrap del device-flow (RFC 8628), NON autenticato:
  #   - authorize: la CLI richiede device_code + user_code + verification_uri.
  #   - token:     la CLI fa poll fino al rilascio del token (o agli errori RFC: pending/slow_down/...).
  class DeviceController < Cli::Api::BaseController
    def authorize
      result = Accounts::Devices::Start.call(client_name: params[:client_name].presence)
      grant = result.value[:grant]
      verification_uri = "#{request.base_url}/cli/authorize"

      render json: {
        data: {
          device_code: result.value[:device_code],
          user_code: grant.user_code,
          verification_uri: verification_uri,
          verification_uri_complete: "#{verification_uri}?user_code=#{grant.user_code}",
          interval: grant.interval,
          expires_in: (grant.expires_at - Time.current).to_i
        }
      }, status: :created
    end

    def token
      result = Accounts::Devices::Poll.call(device_code: params[:device_code].to_s)
      return render_error(result.error.code, result.error.message,
                          status: result.error.status, details: result.error.details) if result.err?

      token = result.value[:token]
      render json: {
        data: {
          access_token: result.value[:access_token],
          # CYRA-717: l'accesso ha una durata, e chi lo ottiene deve saperlo nel momento in cui lo
          # ottiene. `expires_in` (secondi) è la forma RFC 8628 che la CLI si aspetta; `expires_at`
          # accanto evita che debba sommarci sopra l'ora locale per stampare una data.
          expires_in: token.expires_at.present? ? (token.expires_at - Time.current).to_i : nil,
          token: {
            id: token.id, name: token.name, prefix: token.token_prefix,
            expires_at: token.expires_at
          }
        }
      }, status: :created
    end
  end
end
