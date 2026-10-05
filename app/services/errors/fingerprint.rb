# frozen_string_literal: true

module Errors
  # Calcola la chiave di deduplica (fingerprint) di un evento Sentry: occorrenze con lo stesso
  # fingerprint nello stesso progetto formano UN Errors::Group. È il cuore del grouping.
  #
  # Precedenza:
  #   1) fingerprint CLIENT (array dell'SDK). "{{ default }}" significa "includi anche l'algoritmo".
  #   2) ultima exception value: type + culprit (modulo/funzione del frame in-app) — NON il value
  #      (i value contengono ID variabili: spaccherebbero il gruppo a ogni occorrenza).
  #   3) message templato (numeri/uuid/hex normalizzati a placeholder).
  #   4) fallback: transaction.
  class Fingerprint < ApplicationService
    DEFAULT_TOKEN = "{{ default }}"
    UUID_RE = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i

    def initialize(payload:)
      @payload = Errors::Ingest::Scrub.call(payload: payload || {})
    end

    def call
      Digest::SHA256.hexdigest(components.compact.map(&:to_s).reject(&:blank?).join("\n"))
    end

    private

    def components
      custom = custom_fingerprint
      return custom if custom && !custom.include?(DEFAULT_TOKEN)

      base = default_components
      return base unless custom

      base + (custom - [ DEFAULT_TOKEN ])
    end

    def custom_fingerprint
      fp = @payload["fingerprint"]
      return nil unless fp.is_a?(Array) && fp.any?

      fp.map(&:to_s)
    end

    def default_components
      if (exc = last_exception)
        components = [ "exception", exc["type"], culprit_for(exc) ]
        causes = @payload.dig("exception", "values")[0...-1]
        components += [ "causes-v1", *causes.flat_map { |cause| [ cause["type"], culprit_for(cause) ] } ] if causes.any?
        components
      elsif (text = message_text).present?
        [ "message", templatize(text) ]
      else
        [ "transaction", @payload["transaction"].to_s.presence || "unknown" ]
      end
    end

    # Sentry lists the oldest cause first; the last exception is the outer failure.
    def last_exception
      values = @payload.dig("exception", "values")
      return nil unless values.is_a?(Array) && values.any?

      values.last
    end

    # Culprit = "modulo/file . funzione" del frame in-app più vicino al crash (frame line-agnostic:
    # nessun numero di riga → stabile a ogni shift di codice).
    def culprit_for(exc)
      frames = exc.dig("stacktrace", "frames")
      return nil unless frames.is_a?(Array) && frames.any?

      frame = frames.reverse.find { |f| f["in_app"] } || frames.last
      [ frame["module"] || frame["filename"], frame["function"] ].compact.join(".")
    end

    def message_text
      Errors::MessageText.read(@payload)
    end

    def templatize(text)
      text.to_s
          .gsub(UUID_RE, "<uuid>")
          .gsub(/\b0x[0-9a-f]+\b/i, "<hex>")
          .gsub(/\d+/, "<n>")
    end
  end
end
