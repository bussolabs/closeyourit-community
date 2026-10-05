# frozen_string_literal: true

module Analytics
  module Ingest
    # Persiste un batch di pageview con un solo `insert_all`. Idempotente su (project_id, event_id)
    # via ON CONFLICT DO NOTHING. project_id è sempre quello passato (anti-BOLA). Il `context`
    # (visitor_hash/browser/os) è calcolato dal controller via Analytics::Anonymize e vale per
    # tutto il batch (stessa richiesta HTTP = stesso visitatore). Ritorna le righe inserite.
    class Record < ApplicationService
      def initialize(project:, payload:, context:)
        @project = project
        @payload = payload
        @context = (context || {}).stringify_keys
      end

      # Predica di validità di un item (stessa logica di reject di #row_for): un Hash con hostname e
      # path presenti. Esposta per il pre-check sincrono del controller (batch interamente scartato).
      def self.acceptable?(item)
        return false unless item.is_a?(Hash)

        normalized = Normalize.call(payload: item)
        normalized.hostname.present? && normalized.path.present?
      end

      def call
        rows = Array.wrap(@payload).filter_map { |item| row_for(item) }
        return Result.ok(0) if rows.empty?

        # CYRA-750 — nessun bersaglio sul conflitto: la tabella è divisa a fette e su una tabella
        # divisa PostgreSQL accetta un indice unico solo se contiene la colonna del tempo, che
        # renderebbe diversa ogni riconsegna. L'unicità di [progetto, evento] vive quindi sulla SINGOLA
        # fetta (Ops::Partitions) e «salta ciò che viola un vincolo unico qualsiasi» la rispetta
        # esattamente come prima. Resta scoperta solo una riconsegna a cavallo del cambio di mese.
        result = Analytics::Pageview::Bulk.insert_all(rows, returning: %w[id])
        # Solo se sono state scritte righe nuove (RETURNING) → realtime della dashboard di quel
        # progetto; un batch interamente duplicato (idempotenza) non genera refresh.
        Analytics::Broadcast.refresh(@project) if result.count.positive?
        Result.ok(result.count)
      end

      private

      def row_for(item)
        return nil unless item.is_a?(Hash)

        normalized = Normalize.call(payload: item)
        return nil if normalized.hostname.blank? || normalized.path.blank?

        attributes_for(normalized)
      end

      def attributes_for(normalized)
        {
          project_id: @project.id,
          event_id: normalized.event_id,
          name: normalized.name,
          visitor_hash: @context.fetch("visitor_hash"),
          hostname: normalized.hostname,
          path: normalized.path,
          referrer_host: normalized.referrer_host,
          browser: @context["browser"],
          os: @context["os"],
          device_type: @context["device_type"],
          browser_version: @context["browser_version"],
          os_version: @context["os_version"],
          country_code: @context["country_code"],
          utm_source: normalized.utm_source,
          utm_medium: normalized.utm_medium,
          utm_campaign: normalized.utm_campaign,
          utm_term: normalized.utm_term,
          utm_content: normalized.utm_content,
          screen_class: normalized.screen_class,
          environment: normalized.environment,
          occurred_at: normalized.occurred_at,
          created_at: Time.current
        }
      end
    end
  end
end
