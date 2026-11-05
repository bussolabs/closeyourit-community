# frozen_string_literal: true

module Api
  module V1
    # CYRA-1165 — the CI sends the outcome of every test of a run, tied to the version and commit it
    # proved (POST, scope ingest, the project's bearer key like the coverage channel). Every run is
    # kept: the history is the point, unlike the coverage, which keeps the last snapshot.
    class TestRunsController < Api::V1::BaseController
      include RequestBodyLimit

      RUN_FIELDS = %w[version sha branch ran_at duration_ms].freeze

      # The byte cap runs first, before the body is parsed; the test cap is in Projects::TestRuns::Record.
      prepend_before_action :enforce_byte_cap!
      before_action -> { require_scope!(:ingest) }

      def create
        result = ::Projects::TestRuns::Record.call(project: Current.project, params: run_params)
        return render_error(result.error.code, result.error.message, status: result.error.status) unless result.ok?

        render json: { data: TestRunSerializer.new(result.value).as_json }, status: :created
      end

      private

      def enforce_byte_cap!
        return unless request_body_over?(::Projects::TestRun::MAX_PAYLOAD_BYTES)

        render_error("R413-TESTRUN-001",
                     "The report is over #{::Projects::TestRun::MAX_PAYLOAD_BYTES / 1.megabyte} MB: send fewer tests in each run",
                     status: :content_too_large)
      end

      # The report travels as it is: Record checks its shape, field by field.
      def run_params
        RUN_FIELDS.index_with { |key| scalar(params[key]) }.merge("tests" => tests_param)
      end

      def scalar(value)
        value.is_a?(String) || value.is_a?(Numeric) ? value : nil
      end

      def tests_param
        raw = params[:tests]
        return raw unless raw.is_a?(Array)

        raw.map { |entry| entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry }
      end
    end
  end
end
