# frozen_string_literal: true

module Logs
  # CYRA-354 — sopra l'elenco c'erano tre numeri e poi subito la tabella: per scoprire cos'era
  # successo alle tre di notte bisognava sfogliare cinquemila pagine. Questo è il volume nel tempo,
  # che è il modo standard per vedere QUANDO è successo qualcosa.
  #
  # L'aggregazione è in SQL sull'indice (project_id, occurred_at) e SEMPRE limitata a una finestra:
  # raggruppare in Ruby 55k+ righe a ogni caricamento è il modo di rendere lenta la pagina che serve
  # quando le cose vanno male. Un bucket porta il totale e quanti erano allarmanti (error/fatal),
  # perché è la distinzione che si guarda per prima.
  class VolumeBuckets < ApplicationService
    Bucket = Data.define(:from, :to, :count, :alarming)

    # Quanti blocchi disegnare: oltre non si distinguono a occhio, e sotto il picco si perde.
    BUCKETS = 48

    def initialize(scope:, from:, to:)
      @scope = scope
      @from = from
      @to = to
    end

    def call
      return [] if span <= 0

      totals = counts_by_bucket(@scope)
      alarming = counts_by_bucket(@scope.where(level: %i[error fatal]))

      BUCKETS.times.map do |i|
        starts_at = @from + (i * seconds)
        Bucket.new(from: starts_at, to: starts_at + seconds,
                   count: totals.fetch(i, 0), alarming: alarming.fetch(i, 0))
      end
    end

    private

    def span = (@to - @from).to_i

    def seconds = [ span / BUCKETS, 1 ].max

    # width_bucket avrebbe la stessa forma, ma la divisione intera sull'epoch è leggibile e usa lo
    # stesso indice: un solo GROUP BY per serie, nessuna query per blocco. L'espressione passa da
    # sanitize_sql_array — l'inizio finestra e l'ampiezza sono valori legati, mai testo interpolato.
    def bucket_expression
      Arel.sql(ActiveRecord::Base.sanitize_sql_array(
                 [ "FLOOR(EXTRACT(EPOCH FROM (occurred_at - ?::timestamptz)) / ?)", @from.utc, seconds ]
               ))
    end

    def counts_by_bucket(scope)
      scope.reorder(nil)
           .where(occurred_at: @from..@to)
           .group(bucket_expression)
           .count
           .transform_keys(&:to_i)
    end
  end
end
