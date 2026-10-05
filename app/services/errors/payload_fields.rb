# frozen_string_literal: true

module Errors
  # Estrae dal payload Sentry i campi su cui operano le regole di raggruppamento (Errors::GroupingRule):
  # tipo dell'eccezione, culprit, messaggio, transaction. Ricalca la lettura di Errors::Fingerprint
  # (stesso payload, stessa nozione di "ultima exception = punto di crash"), tenuto separato di
  # proposito: Fingerprint è il cuore dell'ingest e non va allargato per un uso di contorno. Le chiavi
  # dell'hash combaciano con i valori dell'enum Errors::GroupingRule#field.
  class PayloadFields < ApplicationService
    def initialize(payload:)
      @payload = payload || {}
    end

    def call
      exc = last_exception
      {
        exception_type: exc && exc["type"],
        culprit: exc && culprit_for(exc),
        message: message_text,
        transaction: @payload["transaction"].presence
      }
    end

    private

    def last_exception
      values = @payload.dig("exception", "values")
      return nil unless values.is_a?(Array) && values.any?

      values.last
    end

    def culprit_for(exc)
      frames = exc.dig("stacktrace", "frames")
      return nil unless frames.is_a?(Array) && frames.any?

      frame = frames.reverse.find { |f| f["in_app"] } || frames.last
      [ frame["module"] || frame["filename"], frame["function"] ].compact.join(".")
    end

    def message_text
      Errors::MessageText.read(@payload)
    end
  end
end
