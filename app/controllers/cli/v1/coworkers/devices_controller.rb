# frozen_string_literal: true

module Cli
  module V1
    module Coworkers
      # `cyi puck connect` (CYRA-1029): the terminal registers this computer, takes the Puck's requests
      # one at a time and sends back what the person allowed. Every request also carries the device
      # token in its body, filtered from the logs like every token.
      class DevicesController < Cli::V1::BaseController
        include CoworkerApi
        before_action :load_device, except: :create

        def create
          device, secret = ::Coworkers::Device.issue(account: Current.account, organization: Current.organization,
                                                     name: params[:name].to_s.strip.presence || "Computer")
          render_created({ id: device.id, token: secret })
        end

        # Heartbeat and next request: delivered once, then it waits for the person's answer.
        def poll
          @device.update_columns(last_seen_at: Time.current)
          call = @device.calls.where(status: "pending").where(created_at: ::Coworkers::Devices::EXPIRES.ago..).order(:created_at).first
          call&.update!(status: "delivered")
          render_ok(call && { id: call.id, tool: call.tool, value: call.arguments["value"], puck: call.run.puck.name })
        end

        def answer
          call = @device.calls.where(status: "delivered").find(params[:call_id])
          allowed = ActiveModel::Type::Boolean.new.cast(params[:allowed])
          call.update!(status: allowed ? (params[:failed].present? ? "failed" : "done") : "denied",
                       result: { "output" => params[:output].to_s.first(24_000) })
          render_ok({ id: call.id, status: call.status })
        end

        def destroy
          @device.update!(revoked_at: Time.current)
          @device.calls.where(status: %w[pending delivered]).update_all(status: "expired", updated_at: Time.current)
          render_no_content
        end

        private

        def load_device
          @device = ::Coworkers::Device.authenticate(params[:device_token])
          render_error("R401-COWORKERS-001", "Unknown or disconnected computer", status: :unauthorized) unless
            @device && @device.account_id == Current.account.id && @device.organization_id == Current.organization.id && @device.id == params[:id]
        end
      end
    end
  end
end
