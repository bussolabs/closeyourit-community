# frozen_string_literal: true

module Ingest
  # Registrazione della fonte OSSERVATA (sdk) durante l'ingest: upsert coalescato via
  # Projects::Source.track!, no-op se manca l'identità del client. Estratta da
  # Errors/Metrics/Logs::Ingest::Record, dove `track_source`/`track_source_batch` vivevano duplicati.
  # Va SEMPRE chiamata dopo il commit, fuori dalla transazione del gruppo/batch (i chiamanti già lo
  # fanno).
  module SourceTracking
    module_function

    # Singolo evento/campione: registra sdk_name/sdk_version/occurred_at del normalized.
    def track_one(project:, normalized:)
      Projects::Source.track!(project: project, tool_code: normalized.sdk_name,
                              version: normalized.sdk_version, occurred_at: normalized.occurred_at)
    end

    # Batch: il primo item con sdk_name presente (identità del client) + l'occurred_at più recente
    # del batch. No-op se nessun item porta un sdk_name.
    def track_batch(project:, items:)
      entry = items.find { |item| item.sdk_name.present? }
      return unless entry

      Projects::Source.track!(project: project, tool_code: entry.sdk_name,
                              version: entry.sdk_version, occurred_at: items.filter_map(&:occurred_at).max)
    end
  end
end
