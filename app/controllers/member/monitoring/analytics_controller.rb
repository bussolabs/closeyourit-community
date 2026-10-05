# frozen_string_literal: true

module Member
  module Monitoring
    # Dashboard web analytics (pageview cookieless) di UN progetto per volta. Lettura per chiunque
    # veda il progetto (scoping visible.projects.analytics_collecting, anti-BOLA 404 — nessuna
    # chiave RBAC: read = visibilità di scope, come logs/errors/metrics). Un progetto compare solo se ha
    # piattaforma web (analytics_capable) E il toggle "Raccogli analytics" attivo (tab Settings, opt-in).
    class AnalyticsController < Member::BaseController
      # CYRA-737 — la base condivisa dell'area di controllo. Questa pagina non è un elenco paginato,
      # ma la tendina dei progetti e il periodo li prende dalla stessa base delle altre.
      include Indexable

      permission_not_required "Traffico di un progetto visibile: sola lettura, il confine è la visibilità del " \
                              "progetto.",
                              only: %i[show]

      def show
        load_filter_projects(visible.projects.analytics_collecting)
        @project = find_project
        @range = ::Analytics::Pageview::BUCKETS.key?(params[:range]) ? params[:range] : ::Analytics::Pageview::DEFAULT_RANGE
        @environment = params[:environment].presence || "production"
        # CYRA-500 — le visite di controllo («il sito è acceso?») restano escluse salvo richiesta:
        # sono visite vere ma non sono persone, e gonfiano ogni totale della pagina.
        @include_automated = ActiveModel::Type::Boolean.new.cast(params[:automated]).present?
        return if @project.nil?

        @environments = @project.environments.order(:position).pluck(:code)
        @filters = current_filters
        # CYRA-503 — la condivisione pubblica sta nella toolbar, quindi serve in ogni stato della
        # pagina: anche sul sito mai collegato, che esce prima di caricare la dashboard.
        @share_link = @project.analytics_links.active.first
        # CYRA-449 — «Nessun dato nel periodo» copriva due situazioni opposte: non hai mai collegato
        # il sito, oppure questa settimana non è passato nessuno. Chi arrivava la prima volta
        # concludeva che la funzione fosse rotta. L'informazione per distinguerle è già nel database.
        @last_pageview_at = ::Analytics::Pageview.where(project_id: @project.id).maximum(:occurred_at)
        @ever_received = @last_pageview_at.present?
        unless @ever_received
          @onboarding_origins = @project.allowed_origins
          # La public key viaggia negli SDK di un sito GIÀ collegato, ma qui il sito non lo è ancora:
          # stamparla darebbe una credenziale di ingest a chi vede il progetto e basta, mentre la
          # pagina dei codici sta dietro tokens.manage. Chi non ha quella chiave vede il segnaposto.
          @can_read_tokens = can?("tokens.manage", scope: @project)
          @onboarding_public_key = @project.tokens.active.order(:created_at).first&.public_key if @can_read_tokens
          @onboarding_public_key ||= t("member.monitoring.analytics.onboarding.key_placeholder")
          return
        end

        load_dashboard
        # Range vuoto ma dati esistenti: invece di stampare quattordici riquadri a zero, un messaggio
        # con la data dell'ultima visita e il periodo più stretto che la contiene.
        @range_empty = @pageviews_count.zero?
        @suggested_range = ::Analytics::Pageview.range_covering(@last_pageview_at) if @range_empty
      end

      private

      # CYRA-924 — the goals panel sorts on its columns (C9), in memory: conversions are computed.
      def goal_sort_columns
        conversion = ->(key) { ->(goal) { @goal_conversions.dig(goal.id, key) } }
        { "goal" => ->(goal) { goal.display_name.to_s.downcase }, "unique" => conversion.(:unique_conversions),
          "total" => conversion.(:total_conversions), "rate" => conversion.(:conversion_rate) }
      end

      # Filtri click-to-filter attivi: solo le chiavi ammesse (allowlist Query::FILTERABLE), blank scartati.
      def current_filters
        params.slice(*::Analytics::Query::FILTERABLE).to_unsafe_h.reject { |_, v| v.to_s.blank? }
      end

      # Progetto esplicito (find sullo scope visibile+capable → 404 cross-tenant o non-web) oppure
      # il primo visibile; nil = nessun progetto analytics-capable → empty state.
      def find_project
        return @projects.find(params[:project_id]) if params[:project_id].present?

        @projects.first
      end

      def load_dashboard
        query = ::Analytics::Query.new(project_id: @project.id, range: @range,
                                       environment: @environment, filters: @filters,
                                       include_automated: @include_automated)
        @buckets = query.timeseries
        @pageviews_count = query.pageviews_count
        @visitors_count = query.visitors_count
        @realtime_count = query.realtime_count
        @realtime_series = query.realtime_series

        @headline = query.headline
        @bounce_rate = @headline[:bounce_rate]
        @visit_duration = @headline[:visit_duration]
        @views_per_visit = @headline[:views_per_visit]

        # Le stesse cinque metriche sul periodo immediatamente precedente: senza una base, «1.240
        # visite» non dice se il sito stia andando meglio o peggio.
        @previous = query.previous_query.headline

        @top_paths = query.top_paths
        @top_referrers = query.top_referrers
        @channels = query.channels
        @entry_pages = query.entry_pages
        @exit_pages = query.exit_pages
        @browsers = query.breakdown(column: "browser")
        @oses = query.breakdown(column: "os")
        @device_types = query.breakdown(column: "device_type")
        @screen_classes = query.breakdown(column: "screen_class")
        @countries = query.breakdown(column: "country_code")
        @utm_sources = query.breakdown(column: "utm_source")
        @utm_mediums = query.breakdown(column: "utm_medium")
        @utm_campaigns = query.breakdown(column: "utm_campaign")
        @utm_terms = query.breakdown(column: "utm_term")
        @utm_contents = query.breakdown(column: "utm_content")
        goals = @project.analytics_goals.ordered.to_a
        @goal_conversions = goals.to_h { |goal| [ goal.id, query.conversions(goal) ] }
        @goals = sorted_rows(goals, columns: goal_sort_columns, param: :goals_sort)
      end
    end
  end
end
