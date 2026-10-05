# frozen_string_literal: true

module Ingest
  # These protocol endpoints parse bounded raw bytes, never form or JSON parameters.
  # Rack otherwise consumes headerless Node envelopes as forms before the controller.
  class RawSentryBody
    PATH = %r{\A/api/[^/]+/(?:envelope|store|minidump)/?\z}

    OTLP_PATH = %r{\A/api/v1/projects/[^/]+/otlp/(?:traces|metrics|logs)/?\z}
    ARTIFACT_PATH = %r{\A/cli/v1/projects/[^/]+/artifacts/(?:source_maps|proguard_maps|native_symbols)(?:\.[^/.?]+)?/?\z}

    def initialize(app)
      @app = app
    end

    def call(env)
      if env["REQUEST_METHOD"] == "POST" && [ PATH, OTLP_PATH, ARTIFACT_PATH ].any? { |path| path.match?(env["PATH_INFO"].to_s) }
        env["rack.request.form_pairs"] = []
        env["rack.request.form_hash"] = {}
        env["action_dispatch.request.request_parameters"] = {}
      end
      @app.call(env)
    end
  end
end
