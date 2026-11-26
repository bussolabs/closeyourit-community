# frozen_string_literal: true

require "delegate"

module Ingest
  # Install before Rails logs the path or instruments the controller, including rejected requests.
  class PrivateRequest
    PATH = %r{\A/api/v1/projects/[^/]+/(?:logs|metrics|pageviews|replays)(?:\.[^/]+)?/?\z}
    PRIVATE_ENV = "closeyourit.private_ingest"

    # Hide keys as well as values, and do not parse an oversized body just to log it.
    module Filtering
      def filtered_parameters
        get_header(PRIVATE_ENV) ? { "payload" => "[FILTERED]" } : super
      end

      def filtered_path
        return super unless get_header(PRIVATE_ENV)

        query_string.empty? ? path : "#{path}?[FILTERED]"
      end
    end

    # ActionDispatch's malformed-JSON diagnostic includes the raw body at debug level.
    class ParserLogger < SimpleDelegator
      def debug(...)
        true
      end
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      if PATH.match?(env["PATH_INFO"].to_s)
        env[PRIVATE_ENV] = true
        env["action_dispatch.parameter_filter"] = [ /./ ]
        logger = env["action_dispatch.logger"]
        env["action_dispatch.logger"] = ParserLogger.new(logger) if logger
      end
      @app.call(env)
    end
  end
end
