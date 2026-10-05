# frozen_string_literal: true

module Analytics
  # Snapshot completo delle statistiche di un progetto+range: l'envelope di lettura condiviso dalla
  # stats API (Api::V1 bearer progetto e Cli::V1 token utente). Dati già aggregati da Analytics::Query
  # (hash primitivi), qui solo composti — nessun accesso DB oltre le query del Query object.
  class Snapshot < ApplicationService
    # Dimensioni esposte nei breakdown dell'API (subset dei BREAKDOWN_COLUMNS, le più utili a un consumer).
    BREAKDOWN_PROPERTIES = %w[browser os device_type country_code utm_source utm_medium utm_campaign].freeze

    def initialize(query:, project:)
      @query = query.dup
      @project = project
    end

    def call
      session = @query.session_summary
      {
        summary: @query.summary.merge(
          bounce_rate: session[:bounce_rate],
          visit_duration: session[:visit_duration],
          views_per_visit: session[:views_per_visit],
          sessions: session[:sessions],
          realtime: @query.realtime_count
        ),
        comparison: @query.comparison.slice(:current, :previous),
        # Wire congelato: solo pageviews/visitors per bucket. L'`:at` che Analytics::Query#timeseries
        # porta per l'asse X della dashboard resta interno alla vista, fuori dal contratto pubblico.
        timeseries: @query.timeseries.map { |b| { pageviews: b[:pageviews], visitors: b[:visitors] } },
        top_pages: @query.top_paths,
        top_referrers: @query.top_referrers,
        channels: @query.channels,
        entry_pages: @query.entry_pages,
        exit_pages: @query.exit_pages,
        breakdowns: BREAKDOWN_PROPERTIES.index_with { |column| @query.breakdown(column: column) },
        goals: @project.analytics_goals.ordered.map { |goal| goal_entry(goal) }
      }
    end

    private

    def goal_entry(goal)
      {
        id: goal.id,
        display_name: goal.display_name,
        kind: goal.kind,
        target: goal.custom_event? ? goal.event_name : goal.path_pattern,
        conversions: @query.conversions(goal)
      }
    end
  end
end
