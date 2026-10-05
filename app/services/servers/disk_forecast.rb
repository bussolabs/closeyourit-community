# frozen_string_literal: true

module Servers
  # Stima in quanti giorni il volume dati di un host saturerà, al ritmo di riempimento attuale
  # (CYRA-679): regressione lineare (minimi quadrati) su data_volume_disk_pct degli ultimi
  # SERVERS_DISK_FORECAST_WINDOW_DAYS giorni di campioni. Più utile della soglia statica: un volume
  # al 60% che cresce del 5%/giorno è più urgente di uno fermo all'88%.
  #
  # Ritorna nil quando una stima onesta non esiste: pochi punti (host nuovo o senza volume dati),
  # pendenza piatta o negativa (non si sta riempiendo), o valore già oltre il 100 per dati sporchi.
  class DiskForecast < ApplicationService
    MIN_SLOPE_PCT_PER_DAY = 0.05

    def initialize(host:, now: Time.current)
      @host = host
      @now = now
    end

    # => { days: Float, slope_pct_per_day: Float, current_pct: Float } | nil
    def call
      points = @host.samples
                    .where(recorded_at: (@now - Servers::Constants::DISK_FORECAST_WINDOW_DAYS.days)..@now)
                    .where.not(data_volume_disk_pct: nil)
                    .order(:recorded_at)
                    .pluck(:recorded_at, :data_volume_disk_pct)
      return Result.ok(nil) if points.length < Servers::Constants::DISK_FORECAST_MIN_POINTS

      slope_per_day, current = regression(points)
      return Result.ok(nil) if slope_per_day < MIN_SLOPE_PCT_PER_DAY || current >= 100

      days = (100.0 - current) / slope_per_day
      Result.ok({ days: days.round(1), slope_pct_per_day: slope_per_day.round(3),
                  current_pct: current.round(2) })
    end

    private

    # Minimi quadrati su (giorni dal primo campione, pct). Il "current" è il valore PREVISTO dalla
    # retta a oggi, non l'ultimo campione: un singolo punto rumoroso non sposta la stima.
    def regression(points)
      t0 = points.first.first
      xs = points.map { |at, _| (at - t0) / 86_400.0 }
      ys = points.map { |_, pct| pct.to_f }
      n = xs.length.to_f
      mean_x = xs.sum / n
      mean_y = ys.sum / n
      denom = xs.sum { |x| (x - mean_x)**2 }
      return [ 0.0, mean_y ] if denom.zero?

      slope = xs.each_with_index.sum { |x, i| (x - mean_x) * (ys[i] - mean_y) } / denom
      now_x = (@now - t0) / 86_400.0
      [ slope, mean_y + slope * (now_x - mean_x) ]
    end
  end
end
