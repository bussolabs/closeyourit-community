# frozen_string_literal: true

# Raccoglie le query SQL applicative emesse durante un blocco per asserire la PRESENZA o (più spesso)
# l'ASSENZA di query specifiche — es. che il path caldo d'ingest NON esegua aggregazioni org-wide
# per-campione (CYRA-41). Esclude SCHEMA/TRANSACTION (rumore di boot/commit).
module SqlCapture
  # CYRA-794 — non solo QUALI query, ma quante righe ognuna ha consegnato a Rails. Una lista non
  # limitata si riconosce solo da lì: `LIMIT` viaggia come parametro (`LIMIT $1`), quindi il testo
  # della query è identico che se ne chiedano dieci o diecimila.
  Query = Data.define(:sql, :rows)

  def captured_queries
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      queries << Query.new(sql: payload[:sql], rows: payload[:row_count])
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def captured_sql(&) = captured_queries(&).map(&:sql)
end

RSpec.configure { |config| config.include SqlCapture }
