# frozen_string_literal: true

require Rails.root.join("lib/ingest/volatile_storage")

# Fail at boot, before Puma accepts traffic; a caller-controlled header cannot assert this gate.
Rails.application.config.x.crash_ingestion_enabled = ENV["CRASH_INGEST_ENABLED"] == "true"
Ingest::VolatileStorage.verify! if Rails.application.config.x.crash_ingestion_enabled
