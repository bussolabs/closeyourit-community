# frozen_string_literal: true

require Rails.root.join("lib/ingest/raw_sentry_body")

Rails.application.config.middleware.insert_before Rack::MethodOverride, Ingest::RawSentryBody
