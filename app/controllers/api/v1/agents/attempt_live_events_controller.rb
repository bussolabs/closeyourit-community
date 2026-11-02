# frozen_string_literal: true

module Api
  module V1
    module Agents
      # CYAU-282 — the agent's steps, sent by the machine running the attempt while it works. Host token
      # (cyi_ah_) like every attempt report; the size is checked before the body is parsed.
      class AttemptLiveEventsController < Api::BaseController
        include AutomatorAuthentication

        MAX_BODY_BYTES = 512 * 1024

        before_action :authenticate_automator_host!

        def create
          if request.content_length.to_i > MAX_BODY_BYTES
            return render_error("R413-LIVE-001", "Live event batch too large", status: :content_too_large)
          end

          attempt = ::Agents::Attempt.where(organization: Current.organization).find(params[:agent_attempt_id])
          events = params[:events].is_a?(Array) ? params[:events].map { it.respond_to?(:to_unsafe_h) ? it.to_unsafe_h : it } : params[:events]
          result = ::Agents::LiveEvents::Record.call(host: Current.agent_host, attempt:, events:)
          return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

          render_ok(result.value)
        rescue ActiveRecord::RecordNotFound
          render_error("R404-ATTEMPT-001", "Attempt not found", status: :not_found)
        end
      end
    end
  end
end
