# frozen_string_literal: true

# CYSK-29 — chi manda usage e da quando; `truncated_last_window` squalifica il kind per lo scanner.
class UsageReporterSerializer < ApplicationSerializer
  attributes :id, :environment, :kind, :sdk_name, :sdk_version, :release,
             :first_reported_at, :last_reported_at, :truncated_last_window
end
