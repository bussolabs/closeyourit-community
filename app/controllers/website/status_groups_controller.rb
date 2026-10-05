# frozen_string_literal: true

module Website
  # Status page PUBBLICA di un GRUPPO di monitor uptime: stato aggregato + un servizio per monitor
  # (stato + timeline + %) + storico incidenti del gruppo. Nessuna autenticazione. Opt-in: visibile
  # SOLO se il gruppo ha `public_status_enabled` (altrimenti 404 — MAI 403). Lookup scoped all'org
  # (via slug) → gruppo (slug): un URL cross-tenant non risolve → 404. Nessun dato interno (url,
  # config, check): solo stato, timeline, SLA, incidenti.
  class StatusGroupsController < BaseController
    def show
      @group = find_public_group
      return head(:not_found) if @group.nil?

      # Come la status per-monitor: mai servire una copia stale da cache condivisa dopo un unpublish.
      response.headers["Cache-Control"] = "no-store"
      allow_iframe_embedding

      @range = range_param
      @monitors = @group.monitors.includes(:project, :environment).order(:name).to_a
      ids = @monitors.map(&:id)
      @buckets = Uptime::Monitor.buckets_for(ids, @range)
      windows = Uptime::Monitor::RANGES.keys.index_with { |key| Time.current - Uptime::Monitor.range_duration(key) }
      # { monitor_id => { window_key => percent|nil } } in una sola query (no N+1 tra i servizi).
      @sla = Uptime::Monitor.uptime_percents_for_windows(ids, windows)
      # Incident TOP-LEVEL di tutti i monitor del gruppo, con label del monitor di riferimento.
      # Preload updates/children (timeline, window_*) + monitor(project,environment) → no N+1.
      @incidents = Uptime::Incident.top_level
                                   .joins(:monitor).where(uptime_monitors: { group_id: @group.id })
                                   .includes(:updates, :children, monitor: %i[project environment])
                                   .recent.limit(20).to_a
      @state = group_state(@monitors)
    end

    # Badge compatto del gruppo, gemello di Website::Status#badge: stesso gate opt-in (non pubblicato
    # → 404), stesso `no-store`, stesso layout autoconsistente. Carica i monitor senza `includes`:
    # `group_state` guarda solo `display_status`, quindi project/environment non servono.
    def badge
      @group = find_public_group
      return head(:not_found) if @group.nil?

      response.headers["Cache-Control"] = "no-store"
      allow_iframe_embedding

      @state = group_state(@group.monitors.to_a)
      render layout: "badge"
    end

    private

    # Risoluzione tenant-scoped: nessun `find` che solleverebbe — sempre `find_by` → nil → 404. Il
    # gate finale è il flag pubblico: un gruppo esistente ma non pubblicato è indistinguibile (per il
    # visitatore) da uno inesistente. Slug normalizzato come il model (downcase).
    def find_public_group
      @org = Organizations::Organization.find_by(slug: params[:org_slug].to_s.strip.downcase)
      return unless @org

      group = @org.uptime_groups.find_by(slug: params[:group_slug].to_s.strip.downcase)
      group if group&.public_status_enabled?
    end

    # Range della timeline; default 30 giorni. Selettore opzionale via ?range=.
    def range_param
      Uptime::Monitor::RANGES.key?(params[:range]) ? params[:range] : "30d"
    end

    # Stato ONESTO aggregato del gruppo, sullo stato VISUALIZZATO (display_status): un dato vecchio (worker
    # dei controlli fermo) conta come unknown, non come l'ultimo up (CYRA-209). down se ≥1 down; operational
    # se tutti up; unknown se nessun monitor o tutti unknown (es. worker fermo); altrimenti degraded (misto).
    def group_state(monitors)
      return "unknown" if monitors.empty?

      displayed = monitors.map(&:display_status)
      return "down" if displayed.include?(:down)
      return "operational" if displayed.all?(:up)
      return "unknown" if displayed.all?(:unknown)

      "degraded"
    end
  end
end
