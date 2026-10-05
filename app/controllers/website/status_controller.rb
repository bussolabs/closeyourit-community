# frozen_string_literal: true

module Website
  # Status page PUBBLICA di un monitor uptime: stato corrente + SLA + timeline + storico incidenti.
  # Nessuna autenticazione. Opt-in: visibile SOLO se il monitor ha `public_status_enabled` (altrimenti
  # 404 — MAI 403, per non rivelare l'esistenza di un monitor non pubblicato). Lookup scoped all'org
  # (via slug) → progetto (key) → environment (code): un URL cross-tenant non risolve → 404.
  # Riusa la stessa logica SLA/timeline dell'area member, potata di ogni dato interno (url, config, check).
  class StatusController < BaseController
    def show
      @monitor = find_public_monitor
      return head(:not_found) if @monitor.nil?

      # Status page = dato che cambia (publish/unpublish, up/down): mai servire una copia stale da
      # cache condivisa dopo un unpublish. `no-store` mantiene la pagina sempre fresca.
      response.headers["Cache-Control"] = "no-store"
      allow_iframe_embedding

      @range = range_param
      @buckets = Uptime::Monitor.buckets_for([ @monitor.id ], @range)[@monitor.id]
      windows = Uptime::Monitor::RANGES.keys.index_with { |key| Time.current - Uptime::Monitor.range_duration(key) }
      percents = Uptime::Monitor.uptime_percents_for_windows([ @monitor.id ], windows)[@monitor.id] || {}
      @sla = Uptime::Monitor::RANGES.keys.index_with { |key| percents[key] }
      # Incident TOP-LEVEL (le finestre unificate collassano nel loro primary); preload updates+children
      # per la timeline e window_* senza N+1 (guard Prosopite).
      @incidents = @monitor.incidents.top_level.recent.includes(:updates, :children).limit(20).to_a
      @open_incident = @monitor.open_incident
      @announcement = @monitor.current_announcement
      @state = monitor_state(@monitor)
    end

    # Badge compatto (pallino + stato) da incorporare in iframe nel sito monitorato. Stesso gate
    # opt-in di #show — non pubblicato → 404 — e stesso `no-store`: se il monitor viene ritirato, il
    # badge già incollato smette di mostrare qualcosa al ricaricamento successivo, senza aspettare
    # una cache. Nessuna query di SLA/timeline/incidenti: qui serve solo lo stato visualizzato.
    def badge
      @monitor = find_public_monitor
      return head(:not_found) if @monitor.nil?

      response.headers["Cache-Control"] = "no-store"
      allow_iframe_embedding

      @state = monitor_state(@monitor)
      render layout: "badge"
    end

    private

    # Risoluzione tenant-scoped: nessun `find` che solleverebbe — sempre `find_by` → nil → 404.
    # Il gate finale è il flag pubblico: un monitor esistente ma non pubblicato è indistinguibile
    # (per il visitatore) da uno inesistente. Espone @org/@project/@environment: la view usa quelli
    # (già in memoria) invece di navigare @monitor.project.organization → nessun accesso lazy, safe
    # anche con strict_loading. Params normalizzati come i model (key upcase, code downcase+underscore).
    def find_public_monitor
      @org = Organizations::Organization.find_by(slug: params[:org_slug].to_s.strip.downcase)
      return unless @org

      @project = @org.projects.find_by(key: params[:project_key].to_s.strip.upcase)
      @environment = @org.environments.find_by(code: params[:environment_code].to_s.strip.downcase.gsub(/\s+/, "_"))
      return unless @project && @environment

      monitor = Uptime::Monitor.find_by(project: @project, environment: @environment)
      monitor if monitor&.public_status_enabled?
    end

    # Range della timeline; default 30 giorni. Selettore opzionale via ?range=.
    def range_param
      Uptime::Monitor::RANGES.key?(params[:range]) ? params[:range] : "30d"
    end

    # Stato ONESTO per il pubblico: un monitor in pausa non è "operational"; e un dato vecchio (worker dei
    # controlli fermo) diventa "unknown" invece di restare un verde ingannevole — via display_status (CYRA-209).
    def monitor_state(monitor)
      return "paused" if monitor.paused?

      { "up" => "operational", "down" => "down", "unknown" => "unknown" }.fetch(monitor.display_status.to_s, "unknown")
    end
  end
end
