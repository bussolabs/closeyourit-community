# frozen_string_literal: true

module Api
  module V1
    # The one read the public key opens (CYRA-1161): is the SDK's version retired, and with which
    # message. Same credentials and site allowlist as ingest; the release is the token's environment's.
    # The browser must check again every time (no-cache): an unchanged answer is a 304 on its ETag.
    class ReleaseStatusesController < Api::V1::IngestBaseController
      def show
        version = params[:version].to_s.strip
        return render_error("R422-RELEASE-002", "version is required", status: :unprocessable_content) if version.blank?

        status = ::Projects::Releases::Status.fetch(project: Current.project, environment: Current.api_token.environment.code,
                                                    version:)
        expires_now
        render_ok(status) if stale?(etag: status)
      end
    end
  end
end
