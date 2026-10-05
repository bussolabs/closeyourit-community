# frozen_string_literal: true

# Ordinamento server-side whitelisted delle tabelle-index. Param unico (`sort`):
# "chiave" = ascendente, "-chiave" = discendente (stile JSON:API). Chiave fuori
# whitelist o param assente → lo scope conserva il SUO ordine di default. Nel SQL
# entra SOLO ciò che è scritto nella whitelist (il param è usato come lookup key
# di Hash) → injection-safe per costruzione.
#
# Con la ricerca semantica dei ticket il sort resta inerte: `searched` gira dopo
# e fa `reorder(nil).in_order_of(...)` — la relevance vince, per design.
module Sortable
  extend ActiveSupport::Concern

  private

  # scope: relation già filtrata (con o senza ordine di default).
  # columns: { "chiave" => spec } — spec:
  #   Symbol → colonna propria del model (auto-qualificata: anti-ambiguità post-join)
  #   String → espressione SQL whitelisted ("LOWER(accounts.name)", subquery COUNT…)
  #   Hash   → { expr: Symbol|String, joins: assoc } — left_outer_joins (MAI inner:
  #            una FK nullable non deve far sparire righe) applicato solo quando la
  #            chiave è quella attiva, niente join a vuoto.
  # NULLS LAST sempre: le righe senza valore restano in fondo in entrambe le direzioni.
  # Tiebreaker id sempre appeso → paginazione deterministica anche sui pari-merito.
  def sorted(scope, columns:, param: :sort)
    key, direction = current_sort(param)
    spec = columns[key]
    return scope if spec.nil?

    spec = { expr: spec } unless spec.is_a?(Hash)
    scope = scope.left_outer_joins(spec[:joins]) if spec[:joins]
    ordering = sort_node(scope, spec[:expr]).public_send(direction)
    scope.reorder(ordering.nulls_last)
         .order(scope.model.arel_table[:id].public_send(direction))
  end

  # CYRA-924 — the same contract for rows already in memory: columns map a key to a lambda reading
  # the value. Missing values stay last in both directions; ties keep the given order.
  def sorted_rows(rows, columns:, param: :sort)
    key, direction = current_sort(param)
    reader = columns[key]
    return rows if reader.nil?

    present, missing = rows.each_with_index.partition { |row, _| !reader.call(row).nil? }
    present = present.sort do |(a, ia), (b, ib)|
      cmp = reader.call(a) <=> reader.call(b)
      cmp = -cmp if direction == :desc
      cmp.zero? ? ia <=> ib : cmp
    end
    (present + missing).map(&:first)
  end

  # ["chiave", :asc | :desc] dal param grezzo ("-chiave" → desc; "" quando assente).
  def current_sort(param = :sort)
    raw = params[param].to_s
    raw.start_with?("-") ? [ raw.delete_prefix("-"), :desc ] : [ raw, :asc ]
  end

  def sort_node(scope, expr)
    expr.is_a?(Symbol) ? scope.model.arel_table[expr] : Arel.sql(expr)
  end
end
