# frozen_string_literal: true

module Routing
  # The web addresses moved to single-word segments; links already sent out (emails, Telegram,
  # bookmarks) still carry the old ones. Used both as the route constraint (only old addresses match)
  # and as the redirect target. Reads the raw request path, never the decoded glob param: decoding
  # would turn `%3F` into a query string and make `%20` an invalid URI.
  module LegacyPaths
    SEGMENTS = {
      "shared_secrets" => "shared/secrets",
      "shared_secret_assets" => "shared/files",
      "personal_secrets" => "personal/secrets",
      "personal_secret_assets" => "personal/files",
      "change_requests" => "requests",
      "guidance_references" => "references",
      "guidance_procedures" => "procedures",
      "todo_lists" => "lists",
      "secret_assets" => "files",
      "status_page" => "status",
      "error_groups" => "error",
      "uptime_groups" => "groups",
      "metric_groups" => "performance",
      "cron_monitors" => "cron",
      "log_entries" => "logs",
      "seo_sites" => "sites",
      "server_tokens" => "tokens",
      "skill_bundle" => "skills",
      "link_suggestions" => "suggestions",
      "two_factor" => "2fa"
    }.freeze

    module_function

    def matches?(request)
      !rewrite(request.path).nil?
    end

    def call(_params, request)
      path = rewrite(request.path)
      request.query_string.present? ? "#{path}?#{request.query_string}" : path
    end

    # nil when no segment was renamed.
    def rewrite(path)
      segments = path.split("/", -1)
      return nil unless segments.any? { |segment| SEGMENTS.key?(segment) }

      segments.map { |segment| SEGMENTS.fetch(segment, segment) }.join("/")
    end
  end
end
