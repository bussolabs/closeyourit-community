# frozen_string_literal: true

module Analytics
  module WebVitals
    # Persiste un batch di misure con un solo `insert_all`, idempotente su (project_id, event_id).
    # Gemello di `Analytics::Ingest::Record`: stesso contratto, stessa forma, altra tabella.
    class Record < ApplicationService
      def initialize(project:, payload:, context:)
        @project = project
        @payload = payload
        @context = (context || {}).stringify_keys
      end

      # Una misura è accettabile se ha una metrica che conosciamo, un valore nei limiti e un
      # indirizzo. Esposta per il pre-check del controller, che scarta il batch intero quando non c'è
      # niente di buono: rispondere 202 a un client che manda solo spazzatura lo lascerebbe
      # convinto di funzionare.
      def self.acceptable?(item)
        return false unless item.is_a?(Hash)

        normalized = Normalize.call(payload: item)
        Seo::Vitals.known?(normalized.metric) && normalized.value.present? &&
          normalized.hostname.present? && normalized.path.present?
      end

      def call
        rows = Array.wrap(@payload).filter_map { |item| row_for(item) }
        return Result.ok(0) if rows.empty?

        Result.ok(Analytics::WebVital.insert_all(rows, unique_by: %i[project_id event_id]).count)
      end

      private

      def row_for(item)
        return nil unless self.class.acceptable?(item)

        attributes_for(Normalize.call(payload: item))
      end

      def attributes_for(normalized)
        {
          project_id: @project.id,
          event_id: normalized.event_id,
          metric: normalized.metric,
          value: normalized.value,
          rating: normalized.rating,
          hostname: normalized.hostname,
          path: normalized.path,
          environment: normalized.environment,
          navigation_type: normalized.navigation_type,
          device_type: @context["device_type"],
          browser: @context["browser"],
          os: @context["os"],
          country_code: @context["country_code"],
          occurred_at: normalized.occurred_at,
          created_at: Time.current
        }
      end
    end
  end
end
