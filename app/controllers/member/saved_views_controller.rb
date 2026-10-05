# frozen_string_literal: true

module Member
  # Viste salvate delle index filtrabili (set di filtri nominati, personali per-org, per risorsa).
  # create salva la selezione corrente; destroy la elimina. Applicare una vista è un GET all'index
  # coi param salvati (nessuna route dedicata). Niente gate RBAC: ognuno gestisce le proprie viste
  # (scope .for → anti-BOLA). Il redirect è server-side (resource_type → path helper): niente
  # open-redirect da param client.
  class SavedViewsController < Member::BaseController
    permission_not_required "Viste salvate personali: ognuno gestisce le proprie, per organizzazione e per risorsa."

    INDEX_HELPERS = {
      # tickets/workload: la lista filtrabile (toolbar + saved views) è su #list, non sull'index
      # (che ora è la board Kanban) → le viste salvate rimandano alla tabella.
      "tickets" => :list_member_tickets_path,
      "ideas" => :member_ideas_path,
      "measurement_series" => :member_monitoring_measurements_path,
      "traces" => :member_monitoring_traces_path,
      "measurement_rules" => :member_monitoring_measurement_rules_path,
      "error_groups" => :member_monitoring_error_groups_path,
      "log_entries" => :member_monitoring_log_entries_path,
      "metric_groups" => :member_monitoring_metric_groups_path,
      "uptime" => :member_monitoring_monitors_path,
      "uptime_groups" => :member_monitoring_uptime_groups_path,
      "workload_actions" => :list_member_workload_actions_path,
      "servers" => :member_monitoring_servers_path,
      "agents" => :member_agents_path,
      "cron_monitors" => :member_monitoring_cron_monitors_path,
      "vulnerabilities" => :member_monitoring_vulnerabilities_path,
      "groups" => :member_groups_path,
      "members" => :member_members_path,
      "platforms" => :member_platforms_path,
      "environments" => :member_environments_path,
      # Nested: il project_id (chiave-filtro salvata) riempie il segmento del path via symbolize_keys.
      "documents" => :member_project_documents_path,
      # Audit del Vault (CYRA-135): risorsa flat → applica/elimina la vista tornando alla pagina Attivita.
      "secret_events" => :member_vault_audit_path
    }.freeze

    before_action :set_resource_type!, only: :create

    def create
      result = SavedViews::Save.call(
        account: Current.account, organization: Current.organization,
        resource_type: @resource_type, name: params[:name], params: filter_source
      )
      if result.ok?
        redirect_to index_path_for(@resource_type, result.value.filters), notice: t("shared.saved_views.saved")
      else
        redirect_to index_path_for(@resource_type, filter_source), alert: result.error.message
      end
    end

    def destroy
      view = SavedView.for(account: Current.account, organization: Current.organization).find(params[:id])
      resource_type = view.resource_type
      # Su risorsa nested il redirect deve portare la chiave-genitore (project_id), altrimenti il
      # path non è generabile. Per le risorse flat lo slice è vuoto → comportamento invariato.
      scope_filters = view.filters.slice(*Array(SavedView::NESTED_SCOPE_KEYS[resource_type]))
      view.destroy
      redirect_to index_path_for(resource_type, scope_filters), notice: t("shared.saved_views.deleted")
    end

    private

    # 404 su risorsa sconosciuta: impedisce di salvare viste con resource_type arbitrario.
    def set_resource_type!
      @resource_type = params[:resource_type].to_s
      head :not_found unless SavedView::RESOURCE_TYPES.include?(@resource_type)
    end

    # Solo le chiavi-filtro ammesse per la risorsa, coi valori grezzi (scalar o array); il model sanifica.
    # CYRA-924 — «Save the filters too» unchecked (include_filters=0) keeps only grouping and sort.
    def filter_source
      keys = params[:include_filters] == "0" ? SavedView.view_keys(@resource_type) : SavedView::FILTER_KEYS.fetch(@resource_type, [])
      keys.index_with { |key| params[key] }
    end

    # symbolize_keys: i filtri arrivano con chiavi STRINGA (jsonb / querystring), ma i segmenti
    # dinamici dei path helper (es. :project_id) si riempiono solo da chiavi SIMBOLO. Sicuro: i
    # filtri sono già sanificati alla allowlist per-risorsa (nessuna option url_for iniettabile).
    # Nested senza scope key (es. save fallito perché manca project_id) → fallback al parent, mai 500.
    def index_path_for(resource_type, filters = {})
      scope_key = SavedView::NESTED_SCOPE_KEYS[resource_type]
      filters = filters.to_h.symbolize_keys
      return member_projects_path if scope_key && filters[scope_key.to_sym].blank?

      public_send(INDEX_HELPERS.fetch(resource_type), filters)
    end
  end
end
