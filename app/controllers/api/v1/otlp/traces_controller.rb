# frozen_string_literal: true

module Api
  module V1
    module Otlp
      class TracesController < Api::V1::BaseController
        MAX_BODY_BYTES = 5 * 1024 * 1024
        before_action -> { require_scope!(:ingest) }

        def create
          return failure("Unsupported content type", :unsupported_media_type) unless request.media_type == "application/json"
          return failure("Unsupported content encoding", :unsupported_media_type) unless request.headers["Content-Encoding"].to_s.in?([ "", "identity" ])
          body = request.body.read(MAX_BODY_BYTES + 1)
          return failure("Request exceeds the byte limit", :content_too_large) if body.bytesize > MAX_BODY_BYTES

          result = ::Traces::Ingest::Record.call(project: Current.project, payload: JSON.parse(body, max_nesting: 64))
          response = result.rejected.zero? ? {} : { partialSuccess: { rejectedSpans: result.rejected.to_s, errorMessage: "Spans rejected by validation or immutable identity conflict" } }
          render json: response, status: :ok
        rescue JSON::ParserError, ::Traces::Ingest::Decode::Malformed
          failure("Malformed OTLP trace request", :bad_request)
        rescue ActiveRecord::ActiveRecordError
          failure("Trace storage is temporarily unavailable", :service_unavailable)
        end

        private

        def failure(message, status)
          render json: { message: message }, status: status
        end

        def render_error(_code, _message, status:, details: nil)
          failure("Request denied", status)
        end
      end
    end
  end
end
