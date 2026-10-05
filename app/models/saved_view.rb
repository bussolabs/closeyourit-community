# frozen_string_literal: true

# Vista salvata su un'index filtrabile: un set di filtri nominato, personale e per-organizzazione,
# discriminato per risorsa (tickets, error_groups, …). Le chiavi-filtro ammesse dipendono dalla
# risorsa (anti-injection di chiavi arbitrarie nella querystring), con gli array dei multi-select
# preservati e i valori vuoti scartati.
class SavedView < ApplicationRecord
  # Chiavi-filtro ammesse per risorsa: rispecchiano i filtri del toolbar di ciascuna index.
  # `sort` (e `invitations_sort` per la seconda tabella di members) viaggia con la vista:
  # il valore non è validato qui — la whitelist SORT_COLUMNS del controller è l'unica fonte
  # di verità (un valore stantio all'apply degrada all'ordine di default, mai SQL).
  FILTER_KEYS = {
    "tickets"       => %w[kind status_id priority_id assignee_id project_id group_id agent_eligibility unassigned overdue workflow q sort],
    "ideas"         => %w[status project_id sort q],
    "measurement_series" => %w[q sort project_id service_name environment attribute_scope attribute_key attribute_type attribute_value],
    "measurement_rules" => %w[q sort],
    "traces" => %w[q project_id service environment version status min_duration_ms max_duration_ms range from to sort],
    "error_groups"  => %w[status level handled project_id q sort],
    # CYRA-355 — `release` entra fra i filtri salvabili: senza, la vista pronta «ultima versione
    # pubblicata» non sarebbe esprimibile, e chi vuole guardare solo il rilascio di oggi non ha modo.
    # CYRA-924 — `grouped` (group by message) and `range` (the period) travel with the view too.
    "log_entries"   => %w[level environment release project_id q from to sort grouped range],
    # CYRA-355 — `seen` (periodo recente) e `open` (non ancora promossi a ticket) erano già leggibili
    # dal controller ma non salvabili: senza, due delle viste pronte non sarebbero esprimibili.
    "metric_groups" => %w[kind subtype status seen open project_id q sort],
    # CYRA-924 — `view` (grouped or one list) and `range` (the period) travel with the view too.
    "uptime"        => %w[status project_id q sort view range],
    "uptime_groups" => %w[q sort],
    "workload_actions" => %w[team_id status participant_id has_ticket q sort],
    "servers"       => %w[status q sort],
    "agents"        => %w[kind enabled q sort],
    "cron_monitors" => %w[status project_id q sort],
    "vulnerabilities" => %w[severity status project_id q sort],
    "groups"        => %w[q sort],
    "members"       => %w[role q sort invitations_sort],
    "platforms"     => %w[status q sort],
    "environments"  => %w[status q sort],
    # Documenti = risorsa NESTED sotto il progetto: project_id riempie il segmento dinamico del
    # path (member_project_documents_path). Senza, il path helper non è generabile → obbligatorio.
    "documents"     => %w[project_id tag q],
    # Audit del Vault (CYRA-135): eventi sui secret. `event_action` perche `action` e riservato in Rails.
    "secret_events" => %w[event_action environment_id actor_id from to q]
  }.freeze

  def self.exact_filter?(resource, key)
    (resource == "measurement_series" && %w[attribute_key attribute_value service_name environment].include?(key)) ||
      (resource == "traces" && %w[service environment version].include?(key))
  end

  RESOURCE_TYPES = FILTER_KEYS.keys.freeze

  # Risorse nested (index sotto un genitore): la chiave che identifica il genitore è obbligatoria
  # nei filtri, altrimenti il path dell'index non è generabile (500 al render del link).
  NESTED_SCOPE_KEYS = { "documents" => "project_id" }.freeze

  belongs_to :account, class_name: "Accounts::Account"
  belongs_to :organization, class_name: "Organizations::Organization"

  normalizes :name, with: ->(value) { value.to_s.strip }

  before_validation :sanitize_filters

  validates :resource_type, presence: true, inclusion: { in: RESOURCE_TYPES }
  validates :name, presence: true, uniqueness: { scope: %i[account_id organization_id resource_type] }
  validate :nested_scope_present

  scope :ordered, -> { order(:name) }
  scope :for_resource, ->(resource_type) { where(resource_type: resource_type) }

  # Viste dell'account corrente nell'org corrente (lo scope è anche anti-BOLA per find/destroy).
  def self.for(account:, organization:)
    where(account_id: account.id, organization_id: organization.id)
  end

  # CYRA-924 — the keys that say how the list looks (grouping, sort), not which rows it shows: a view
  # saved without its filters keeps only these.
  def self.view_keys(resource_type)
    FILTER_KEYS.fetch(resource_type, []).select { |key| %w[view grouped sort].include?(key) || key.end_with?("_sort") }
  end

  # Chiavi-filtro ammesse per questa risorsa (vuoto se resource_type sconosciuto).
  def allowed_filter_keys
    FILTER_KEYS.fetch(resource_type, [])
  end

  private

  # Tiene solo le chiavi-filtro ammesse per la risorsa, scartando i valori vuoti (array svuotati o "").
  def sanitize_filters
    raw = filters.is_a?(Hash) ? filters : {}
    cleaned = {}
    allowed_filter_keys.each do |key|
      exact = self.class.exact_filter?(resource_type, key) && raw[key].is_a?(String)
      value = exact ? raw[key] : clean_value(raw[key])
      cleaned[key] = value if exact || value.present?
    end
    self.filters = cleaned
  end

  def clean_value(value)
    return value.reject(&:blank?) if value.is_a?(Array)

    value.to_s.strip
  end

  # Su risorsa nested la chiave-genitore (es. project_id) deve esserci nei filtri sanificati.
  def nested_scope_present
    scope_key = NESTED_SCOPE_KEYS[resource_type]
    return if scope_key.nil?
    return if filters.is_a?(Hash) && filters[scope_key].present?

    errors.add(:base, :missing_scope)
  end
end
