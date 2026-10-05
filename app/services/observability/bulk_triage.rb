# frozen_string_literal: true

module Observability
  # Base condivisa del triage in massa di gruppi di monitoring (CYRA-45): dopo un deploy rumoroso,
  # resolve/ignore di N gruppi in un colpo dalla lista. Riusa la Triage di dominio per gruppo, in UNA
  # transazione (o tutti o nessuno). Anti-BOLA: `scope` è già la relation dei gruppi visibili (Member:
  # filtrata per permesso; CLI: gattata sul progetto) → gli id fuori scope non fanno match e vengono
  # scartati. Ritorna i gruppi toccati (conteggio del notice + broadcast batch, che vive nel canale
  # Member).
  #
  # Le sottoclassi dichiarano la Triage di dominio (`triage_class`) e il codice errore; solo se il
  # dominio lo richiede, il preload da fare sui gruppi e le opzioni extra da passare alla Triage.
  class BulkTriage < ApplicationService
    def initialize(scope:, ids:, action:)
      @scope = scope
      @ids = Array(ids).reject(&:blank?)
      @action = action.to_s
    end

    def call
      unless triage_class::ACTIONS.key?(@action)
        return Result.err(AppError.new("Azione triage non valida", code: invalid_action_code))
      end

      groups = load_groups
      context = triage_context(groups)
      ActiveRecord::Base.transaction do
        groups.each { |group| triage_class.call(group:, action: @action, **triage_options(group, context)) }
      end
      Result.ok(groups)
    end

    private

    def load_groups
      relation = @scope.where(id: @ids)
      relation = relation.includes(*group_includes) if group_includes.any?
      relation.to_a
    end

    # Associazioni da precaricare sui gruppi prima del triage batch (default: nessuna).
    def group_includes = []

    # Contesto calcolato UNA volta sull'intero batch e passato a ogni triage (default: nessuno). Gli
    # errori lo usano per precalcolare la release live per progetto ed evitare l'N+1 dell'audit.
    def triage_context(_groups) = {}

    # Opzioni extra passate alla Triage di dominio per ciascun gruppo (default: nessuna).
    def triage_options(_group, _context) = {}

    def triage_class = raise NotImplementedError, "#{self.class} deve definire triage_class"
    def invalid_action_code = raise NotImplementedError, "#{self.class} deve definire invalid_action_code"
  end
end
