# frozen_string_literal: true

module Agents
  module Attempts
    # Quanto è costata l'automazione di un'organizzazione in una settimana UTC (da lunedì), per fase e per progetto.
    # Conta i tentativi conclusi nella settimana; `priced` sono quelli con un costo dichiarato (CYRA-872).
    class WeeklyCosts < ApplicationService
      Row = Data.define(:label, :attempts, :priced, :cost) do
        def line = format("%-20s %d tentativi, %d con costo %9s", label, attempts, priced, format("$%.2f", cost))
      end

      Report = Data.define(:range, :by_phase, :by_project, :total) do
        def lines
          header = "Costi dell'automazione dal #{range.begin.to_date} al #{(range.end - 1).to_date} (UTC)"
          return [ header, "Nessun tentativo concluso." ] if total.attempts.zero?

          [ header, "", "Per fase:", *by_phase.map { "  #{it.line}" },
            "", "Per progetto:", *by_project.map { "  #{it.line}" }, "", total.line.sub("totale", "Totale") ]
        end
      end

      TOTALS = [ Arel.sql("COUNT(*)"), Arel.sql("COUNT(agents_attempts.cost_usd)"),
                 Arel.sql("COALESCE(SUM(agents_attempts.cost_usd), 0)") ].freeze

      def initialize(organization:, week:)
        @organization = organization
        monday = week.to_date.beginning_of_week(:monday)
        @range = Time.utc(monday.year, monday.month, monday.day)...Time.utc(monday.year, monday.month, monday.day) + 7.days
      end

      def call
        by_phase = rows(scope.group(:phase).order(:phase).pluck(:phase, *TOTALS))
        key = Projects::Project.arel_table[:key]
        by_project = rows(scope.joins(workflow: { ticket: :project }).group(key).order(key).pluck(key, *TOTALS))
        Report.new(range: @range, by_phase:, by_project:, total: rows([ [ "totale", *scope.pick(*TOTALS) ] ]).first)
      end

      private

      def scope = Agents::Attempt.where(organization: @organization, finished_at: @range)

      def rows(values)
        values.map { |label, attempts, priced, cost| Row.new(label:, attempts:, priced:, cost: BigDecimal(cost.to_s)) }
      end
    end
  end
end
