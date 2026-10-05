# frozen_string_literal: true

module Crons
  # CYRA-484 — la cronologia dei guasti di un lavoro programmato. Non esiste un modello di incident
  # per i cron (a differenza dell'uptime) e non serve inventarne uno: un guasto È una serie di
  # tentativi falliti consecutivi, e si ricostruisce dai check-in che ci sono già.
  #
  # Venti fallimenti di fila sono UN guasto durato dalle 3 alle 5, non venti righe da contare a mano.
  # Il guasto ancora aperto (l'ultimo, se l'ultimo tentativo è fallito) non ha una fine.
  class IncidentHistory < ApplicationService
    Incident = Data.define(:started_at, :ended_at, :attempts, :reason) do
      def open? = ended_at.nil?
    end

    # Quanti check-in guardare indietro: oltre non è più cronologia, è archeologia — e la pagina ne
    # mostra comunque una manciata.
    WINDOW = 500

    def initialize(monitor:, limit: 10)
      @monitor = monitor
      @limit = limit
    end

    def call
      # In ordine cronologico: un guasto si legge dall'inizio alla fine, non al contrario.
      check_ins = @monitor.check_ins.order(checked_in_at: :desc).limit(WINDOW).to_a.reverse
      incidents = []
      current = nil

      check_ins.each do |check_in|
        if check_in.status_fail?
          current = open_incident(current, check_in)
        elsif current
          incidents << close(current, check_in.checked_in_at)
          current = nil
        end
      end
      incidents << current if current

      incidents.reverse.first(@limit)
    end

    private

    # Il motivo del guasto è quello del PRIMO tentativo fallito: è la causa, quelli dopo sono la
    # conseguenza. Un guasto senza motivo resta senza motivo — meglio del motivo sbagliato.
    def open_incident(current, check_in)
      return Incident.new(started_at: check_in.checked_in_at, ended_at: nil, attempts: 1,
                          reason: check_in.reason) if current.nil?

      current.with(attempts: current.attempts + 1)
    end

    def close(incident, moment)
      incident.with(ended_at: moment)
    end
  end
end
