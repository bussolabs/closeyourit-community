# frozen_string_literal: true

module App
  # A community install on someone's own server (CYRA-1035). Only the community compose.yml sets the
  # flag, so closeyour.it never shows the update notice nor accepts an update request.
  module SelfHosted
    module_function

    REPO = "bussolabs/closeyourit-community"

    def enabled? = ENV["CLOSEYOURIT_SELF_HOSTED"] == "true"

    # Shared with the host: the app writes inbox/, the host writes status/ (mounted read-only).
    def updates_dir = Pathname(ENV.fetch("CLOSEYOURIT_UPDATES_DIR", "/rails/updates"))

    # A mirror can stand in for GitHub; the installer writes the same two values into .env.
    def releases_api = ENV["CLOSEYOURIT_RELEASES_API"].presence || "https://api.github.com/repos/#{REPO}"
    def releases_raw = ENV["CLOSEYOURIT_RELEASES_RAW"].presence || "https://raw.githubusercontent.com/#{REPO}"
  end
end
