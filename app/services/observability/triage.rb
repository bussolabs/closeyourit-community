# frozen_string_literal: true

module Observability
  # Base condivisa dello smistamento (triage) di un gruppo di monitoring: cambia lo stato
  # (resolve/ignore/reopen) e ritorna il Result. reopen riporta a unresolved (da resolved o ignored).
  # Errors::Triage e Metrics::Triage la specializzano: forniscono il codice errore del proprio dominio
  # e, se serve, gli attributi extra da scrivere insieme allo status (es. l'audit di regressione
  # release-aware degli errori). Condiviso da API, CLI e UI Member.
  class Triage < ApplicationService
    ACTIONS = { "resolve" => :resolved, "ignore" => :ignored, "reopen" => :unresolved }.freeze

    def initialize(group:, action:)
      @group = group
      @action = action.to_s
    end

    def call
      target = self.class::ACTIONS[@action]
      return Result.err(AppError.new("Azione triage non valida", code: invalid_action_code)) unless target

      @group.update!(status: target, **extra_attributes(target))
      Result.ok(@group)
    end

    private

    # Attributi aggiuntivi da scrivere con lo status. Default: nessuno (le performance non hanno audit
    # di regressione — una query lenta non regredisce per release). Gli errori lo estendono.
    def extra_attributes(_target) = {}

    def invalid_action_code = raise NotImplementedError, "#{self.class} deve definire invalid_action_code"
  end
end
