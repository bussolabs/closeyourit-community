# frozen_string_literal: true

module Api
  module V1
    module Otlp
      class MetricsController < Api::V1::BaseController
        MAX_BODY_BYTES = 5 * 1024 * 1024
        before_action -> { require_scope!(:ingest) }

        def create
          return failure("Unsupported content type", :unsupported_media_type) unless request.media_type == "application/json"
          return failure("Unsupported content encoding", :unsupported_media_type) unless request.headers["Content-Encoding"].to_s.in?([ "", "identity" ])
          body = request.body.read(MAX_BODY_BYTES + 1)
          return failure("Request exceeds the byte limit", :content_too_large) if body.bytesize > MAX_BODY_BYTES
          result = ::Measurements::Ingest::Record.call(project: Current.project, payload: JSON.parse(body, max_nesting: 64))
          response = result.rejected.zero? ? {} : { partialSuccess: { rejectedDataPoints: result.rejected.to_s,
            errorMessage: "Metric points rejected by validation, immutable identity conflict or active series limit" } }
          render json: response, status: :ok
        rescue JSON::ParserError, ::Measurements::Ingest::Decode::Malformed
          failure("Malformed OTLP metric request", :bad_request)
        rescue ActiveRecord::ActiveRecordError
          failure("Metric storage is temporarily unavailable", :service_unavailable)
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
