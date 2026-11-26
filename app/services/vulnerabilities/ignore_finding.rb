# frozen_string_literal: true

module Vulnerabilities
  # CYRA-1144 — l'unico modo di ignorare una vulnerabilità, condiviso da pagina e riga di comando.
  # Ignorare è una decisione a tempo: serve un motivo e il giorno in cui scade, e si registra chi
  # l'ha presa. La regola vive sul model (contesto `:ignore`) e qui non ci sono eccezioni per nessun
  # canale: una versione vecchia del comando, che non manda né motivo né scadenza, viene rifiutata
  # come chiunque altro — un'eccezione renderebbe facoltativo ciò che è obbligatorio.
  #
  # Il giorno di scadenza Vulnerabilities::ReopenExpiredIgnores la riapre e avvisa.
  class IgnoreFinding < ApplicationService
    ERROR_CODE = "R422-VULNERABILITY-001"

    # `ignored_until` arriva come testo (ISO 8601, «2026-12-01») o come Date: il cast della colonna
    # lo converte, e un testo che non è una data diventa nil, cioè «scadenza mancante».
    def initialize(finding:, reason:, ignored_until:, actor:)
      @finding = finding
      @reason = reason.to_s.strip.presence
      @ignored_until = ignored_until
      @actor = actor
    end

    def call
      @finding.assign_attributes(status: :ignored, triage_note: @reason, ignored_until: @ignored_until,
                                 ignored_by: @actor)
      return Result.ok(@finding) if @finding.save(context: :ignore)

      # Il messaggio senza il nome del campo: ogni errore è già una frase che dice cosa manca.
      message = @finding.errors.map(&:message).to_sentence
      details = @finding.errors.to_hash
      # La riga resta com'era: chi rilegge la pagina dopo il rifiuto deve vederla ancora aperta.
      @finding.restore_attributes
      Result.err(AppError.new(message, code: ERROR_CODE, details: details))
    end
  end
end
