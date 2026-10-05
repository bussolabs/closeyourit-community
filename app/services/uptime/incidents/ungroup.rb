# frozen_string_literal: true

module Uptime
  module Incidents
    # Scioglie il raggruppamento: stacca TUTTI i figli del primary (tornano incident top-level a sé).
    # La narrazione (phase + updates) resta di default sul primary, ma può essere TRASFERITA a una
    # finestra scelta (`keep_incident_id`) prima dello scioglimento: è la finestra che "tiene lo status".
    # Atomico (transazione); idempotente (nessun figlio → no-op). Il broadcast è fuori transazione e
    # resiliente (vedi Broadcast): un suo fallimento non fa fallire lo split già committato.
    class Ungroup < ApplicationService
      def initialize(incident:, keep_incident_id: nil, actor: nil)
        @incident = incident
        @keep_incident_id = keep_incident_id
        @actor = actor
      end

      def call
        keeper = resolve_keeper
        ActiveRecord::Base.transaction do
          move_narration_to(keeper) unless keeper.id == @incident.id
          @incident.children.update_all(parent_id: nil)
        end
        Broadcast.incidents(@incident.monitor)
        Result.ok(@incident)
      end

      private

      # Finestra che conserva la narrazione: il primary di default, oppure un suo figlio scelto.
      # keep_incident_id assente/estraneo → primary (fail-safe: mai spostare lo status su un non-figlio).
      def resolve_keeper
        return @incident if @keep_incident_id.blank? || @keep_incident_id.to_s == @incident.id.to_s

        @incident.children.find_by(id: @keep_incident_id) || @incident
      end

      # Trasferisce phase + timeline dal primary alla finestra scelta prima di sciogliere: keeper diventa
      # l'incident narrato, il primary torna una finestra nuda. Ordine: leggi la phase del primary PRIMA
      # di azzerarla.
      def move_narration_to(keeper)
        keeper.update!(phase: @incident.phase)
        @incident.updates.update_all(incident_id: keeper.id)
        @incident.update!(phase: nil)
      end
    end
  end
end
