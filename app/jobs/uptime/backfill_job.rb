# frozen_string_literal: true

module Uptime
  # One-shot al primo deploy del rollup: finora i ping raw non venivano MAI potati → hanno tutta la storia.
  # Genera gli hourly (dai raw) e poi i daily (dagli hourly appena creati) sull'intera finestra, così la
  # vista annuale ha dati da subito. Idempotente (upsert). DEVE girare PRIMA del primo Uptime::PruneJob,
  # altrimenti il raw oltre 3gg viene potato prima di essere aggregato e la storia si perde.
  class BackfillJob < ApplicationJob
    queue_as :batch

    def perform
      earliest = Uptime::Check.granularity_check.minimum(:checked_at)
      return if earliest.nil?

      Uptime::RollupJob.perform_now("hourly", since: earliest)
      Uptime::RollupJob.perform_now("daily", since: earliest)
    end
  end
end
