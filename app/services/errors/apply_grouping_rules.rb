# frozen_string_literal: true

module Errors
  # Applica le regole di raggruppamento del progetto a un fingerprint appena calcolato (CYRA-153). La
  # PRIMA regola attiva, in ordine di position, che soddisfa il match sull'occorrenza rimappa il
  # fingerprint; nessuna regola che matcha → fingerprint invariato.
  #
  # Sta sul path caldo dell'ingest (Errors::Ingest::Record): ritorna una stringa (il fingerprint), non
  # un Result. Con zero regole paga una sola query indicizzata che torna vuota e non estrae nemmeno i
  # campi dal payload — il costo sul progetto che non usa la feature è quello.
  class ApplyGroupingRules < ApplicationService
    def initialize(project:, payload:, fingerprint:)
      @project = project
      @payload = payload
      @fingerprint = fingerprint
    end

    def call
      rules = @project.error_grouping_rules.active.ordered.to_a
      return @fingerprint if rules.empty?

      fields = Errors::PayloadFields.call(payload: @payload)
      rule = rules.find { |r| r.matches?(fields) }
      rule ? rule.target_fingerprint : @fingerprint
    end
  end
end
