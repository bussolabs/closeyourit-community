# frozen_string_literal: true

module Uptime
  # Rollup persistiti nella STESSA tabella (`uptime_checks`, discriminatore `granularity`): un solo job
  # produce entrambi i livelli aggregati.
  #   - `hourly`: aggrega i ping raw delle ore CHIUSE → 1 riga per [monitor, ora].
  #   - `daily` : aggrega gli hourly dei giorni CHIUSI → 1 riga per [monitor, giorno] + denorm incident
  #               (incidents_count/downtime_seconds dall'overlap di uptime_incidents sul giorno).
  # Upsert idempotente sull'indice unico parziale (granularity <> 0). `since` opzionale = backfill
  # all-history (default: solo le ultime LOOKBACK finestre, per recuperare uno skip).
  class RollupJob < ApplicationJob
    queue_as :batch

    # Finestre chiuse ricalcolate a ogni run (recupero da skip): 3 ore indietro / 3 giorni indietro.
    LOOKBACK = 3

    DISPATCH = { "hourly" => :roll_hourly, "daily" => :roll_daily }.freeze

    def perform(granularity, since: nil)
      __send__(DISPATCH.fetch(granularity.to_s), since)
    end

    private

    # Ping raw → bucket orari. Solo ore chiuse: [window_start, inizio ora corrente). Boundary in UTC:
    # `checked_at` è salvato UTC e `date_trunc` opera sul wall-clock UTC → i confini DEVONO essere UTC
    # (con `Time.current` in zona Rome, beginning_of_day/hour sfaserebbe di 1-2h).
    def roll_hourly(since)
      now = Time.current.utc
      boundary = now.beginning_of_hour
      window_start = since || (boundary - LOOKBACK.hours)
      bucket = "date_trunc('hour', checked_at)"

      rows = Uptime::Check.granularity_check
                          .where(checked_at: window_start...boundary)
                          .group(Arel.sql("monitor_id"), Arel.sql(bucket))
                          .pluck(Arel.sql("monitor_id"), Arel.sql(bucket), Arel.sql("COUNT(*)"),
                                 Arel.sql("COUNT(*) FILTER (WHERE up)"),
                                 Arel.sql("AVG(response_time_ms) FILTER (WHERE up)"))

      upsert(rows.map do |mid, bucket_at, total, up, avg|
        base_row(mid, :hourly, bucket_at, total, up, avg)
      end, %i[checks_total checks_up avg_response_ms])
    end

    # Bucket orari → bucket giornalieri (+ denorm incident). Solo giorni chiusi: [window_start, oggi 00:00 UTC).
    # Boundary in UTC (vedi roll_hourly): la giornata del rollup è il giorno UTC, coerente con date_trunc.
    def roll_daily(since)
      now = Time.current.utc
      boundary = now.beginning_of_day
      window_start = since ? since.utc.beginning_of_day : (boundary - LOOKBACK.days)
      bucket = "date_trunc('day', checked_at)"

      rows = Uptime::Check.granularity_hourly
                          .where(checked_at: window_start...boundary)
                          .group(Arel.sql("monitor_id"), Arel.sql(bucket))
                          .pluck(Arel.sql("monitor_id"), Arel.sql(bucket), Arel.sql("SUM(checks_total)"),
                                 Arel.sql("SUM(checks_up)"),
                                 Arel.sql("SUM(avg_response_ms * checks_up)::float / NULLIF(SUM(checks_up), 0)"))

      upsert(rows.map do |mid, day, total, up, avg|
        down_seconds, incidents = incident_stats(mid, day)
        base_row(mid, :daily, day, total, up, avg)
          .merge(incidents_count: incidents, downtime_seconds: down_seconds)
      end, %i[checks_total checks_up avg_response_ms incidents_count downtime_seconds])
    end

    # created_at/updated_at li gestisce upsert_all (record_timestamps): passarli a mano duplicherebbe la
    # SET su updated_at (PG: "multiple assignments to same column").
    def base_row(monitor_id, granularity, bucket_at, total, up, avg)
      { monitor_id: monitor_id, granularity: Uptime::Check.granularities[granularity.to_s], checked_at: bucket_at,
        checks_total: total, checks_up: up, avg_response_ms: avg&.round }
    end

    def upsert(records, update_columns)
      return if records.empty?

      Uptime::Check.upsert_all(records, unique_by: :index_uptime_rollups_unique, update_only: update_columns)
    end

    # Secondi di down e numero di incident che si sovrappongono al giorno [day, day+1). Un incident aperto
    # (resolved_at nil) è considerato in corso fino a ora. Fonte di verità = uptime_incidents (mai potata).
    def incident_stats(monitor_id, day)
      day_end = day + 1.day
      incidents = Uptime::Incident.where(monitor_id: monitor_id)
                                  .where(started_at: ...day_end)
                                  .where("resolved_at IS NULL OR resolved_at > ?", day)
                                  .to_a
      seconds = incidents.sum do |incident|
        from = [ incident.started_at, day ].max
        to = [ incident.resolved_at || Time.current, day_end ].min
        to > from ? (to - from).to_i : 0
      end
      [ seconds, incidents.size ]
    end
  end
end
