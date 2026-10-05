# frozen_string_literal: true

module Reports
  # I numeri del riepilogo periodico via email (CYRA-160): traffico, errori e disponibilità dei siti
  # di UNA persona in UNA organizzazione, sulla finestra della sua frequenza.
  #
  # Il digest che già esisteva (Notifications::DigestJob) riassume le NOTIFICHE trattenute: cose
  # già accadute e già annunciate una per una. Qui si riassumono i DATI, che nessuna email portava:
  # per saperli bisognava entrare e guardare le pagine.
  #
  # Perché non riusare Analytics::Query, Errors::Group.buckets_for e le altre letture della
  # dashboard: sono tutte per-progetto, e un riepilogo che le chiamasse in un ciclo su N progetti
  # farebbe N query identiche per ogni numero (il guard N+1 lo vedrebbe, e a ragione). Qui ogni
  # numero è UNA query raggruppata su tutti i progetti visibili — il conto è lo stesso, la finestra
  # e i filtri sono gli stessi (compresi gli indirizzi di controllo esclusi dal traffico), il numero
  # di query non dipende da quanti progetti si hanno.
  class PeriodicSummary < ApplicationService
    # Quanti progetti stanno nella tabella dell'email. Oltre, l'email diventa un tabulato che nessuno
    # legge: si mostrano i più attivi e si dice quanti altri ci sono.
    MAX_ROWS = 10

    SPANS = { "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    # Dove leggere la disponibilità: i ping veri coprono solo gli ultimi giorni (potati a 3), le
    # finestre lunghe leggono i bucket orari già aggregati. Stessa scelta della vista uptime.
    UPTIME_SOURCES = { "24h" => :raw, "7d" => :hourly, "30d" => :hourly }.freeze

    Row = Data.define(:project_id, :name, :pageviews, :visitors, :error_events, :uptime_percent)

    Result = Data.define(:cadence, :range, :from, :to, :rows, :other_projects,
                         :pageviews, :visitors, :previous_pageviews,
                         :error_events, :new_error_groups, :open_error_groups, :uptime_percent) do
      # Nessuna riga = nessun progetto ha prodotto un solo dato nel periodo. Un'email che dice zero
      # su tutto non informa nessuno: chi la riceve la legge come rumore.
      def any_data? = rows.any?

      # Variazione percentuale sul periodo precedente, nil se prima non c'era traffico: da zero non
      # esiste una percentuale, e scriverne una qualsiasi sarebbe un numero inventato.
      def pageviews_delta
        return nil if previous_pageviews.to_i.zero?

        (((pageviews - previous_pageviews) / previous_pageviews.to_f) * 100).round
      end
    end

    def initialize(account:, organization:, cadence:, now: Time.current)
      @account = account
      @organization = organization
      @cadence = cadence.to_s
      @now = now
    end

    def call
      Result.new(cadence: @cadence, range: range, from: from, to: @now,
                 rows: rows.first(MAX_ROWS), other_projects: [ rows.size - MAX_ROWS, 0 ].max,
                 pageviews: total(:pageviews), visitors: total(:visitors),
                 previous_pageviews: previous_pageviews,
                 error_events: error_events_by_project.values.sum,
                 new_error_groups: new_error_groups, open_error_groups: open_error_groups,
                 uptime_percent: overall_uptime_percent)
    end

    private

    def range = @range ||= Alerting::Preference::REPORT_RANGES.fetch(@cadence, "7d")
    def span = SPANS.fetch(range)
    def from = @from ||= @now - span

    def projects
      @projects ||= Authorization::VisibleScope.new(account: @account, organization: @organization)
                                               .projects.pluck(:id, :name).to_h
    end

    def project_ids = projects.keys

    # Solo i progetti che hanno qualcosa da dire, dal più attivo: un elenco di zeri non è un
    # riepilogo. A parità di traffico decide chi ha più errori, poi il nome (ordine stabile).
    def rows
      @rows ||= project_ids.filter_map do |id|
        pageviews, visitors = traffic_by_project.fetch(id, [ 0, 0 ])
        errors = error_events_by_project.fetch(id, 0)
        uptime = uptime_by_project[id]
        next if pageviews.zero? && errors.zero? && uptime.nil?

        Row.new(project_id: id, name: projects[id], pageviews: pageviews, visitors: visitors,
                error_events: errors, uptime_percent: uptime)
      end.sort_by { |row| [ -row.pageviews, -row.error_events, row.name.to_s ] }
    end

    def total(field) = rows.sum(&field)

    # --- letture ------------------------------------------------------------------------------

    def traffic_by_project
      @traffic_by_project ||= pageview_scope(from, @now)
                                .group(:project_id)
                                .pluck(:project_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT visitor_hash)"))
                                .to_h { |id, views, visitors| [ id, [ views, visitors ] ] }
    end

    # Il periodo immediatamente precedente, stessa durata: senza confronto «1.200 visite» non dice
    # se è andata bene. Solo il totale — il confronto per progetto sarebbe una tabella nell'email.
    def previous_pageviews
      @previous_pageviews ||= pageview_scope(from - span, from).count
    end

    def pageview_scope(since, until_at)
      Analytics::Pageview
        .where(project_id: project_ids, name: Analytics::Pageview::PAGEVIEW_NAME,
               occurred_at: since...until_at)
        .where.not(path: Analytics::Query::AUTOMATED_PATHS)
    end

    def error_events_by_project
      @error_events_by_project ||= Errors::Event.where(project_id: project_ids, occurred_at: from...@now)
                                                .group(:project_id).count
    end

    def new_error_groups
      @new_error_groups ||= Errors::Group.where(project_id: project_ids, first_seen_at: from...@now).count
    end

    # Quelli ancora aperti NON sono ristretti alla finestra: è il debito che resta acceso adesso,
    # e comprende i problemi vecchi che nessuno ha chiuso.
    def open_error_groups
      @open_error_groups ||= Errors::Group.status_unresolved.where(project_id: project_ids).count
    end

    def monitors_by_project
      @monitors_by_project ||= Uptime::Monitor.where(project_id: project_ids).pluck(:id, :project_id)
    end

    # % per monitor sulla finestra, in una query sola (il metodo del modello è già batch).
    def uptime_percents
      @uptime_percents ||= Uptime::Monitor.uptime_percents(monitors_by_project.map(&:first), from,
                                                           source: UPTIME_SOURCES.fetch(range))
    end

    # Media dei monitor del progetto: ogni monitor pesa uno, senza monitor con dati resta nil (che
    # è diverso da 0% — «non misurato» non è «giù»).
    def uptime_by_project
      @uptime_by_project ||= monitors_by_project.group_by(&:last).transform_values do |pairs|
        values = pairs.filter_map { |monitor_id, _project_id| uptime_percents[monitor_id] }
        average(values)
      end.compact
    end

    def overall_uptime_percent = average(uptime_percents.values.compact)

    def average(values)
      return nil if values.empty?

      (values.sum / values.size.to_f).round(2)
    end
  end
end
