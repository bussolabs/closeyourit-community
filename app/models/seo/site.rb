# frozen_string_literal: true

module Seo
  # Un sito da tenere d'occhio: dove attaccare la visita, quanto spesso, fin dove spingersi.
  # Uno per [progetto, ambiente] come Uptime::Monitor — staging e produzione dello stesso progetto
  # dicono cose diverse e vanno guardati separatamente.
  #
  # La cadenza vera la decide `next_audit_at`, scritto a fine giro: il dispatcher gira a ore fisse e
  # si limita a chiedere chi è scaduto. Così cambiare `frequency` non richiede di riprogrammare
  # niente — il prossimo giro ricalcola da sé.
  class Site < ApplicationRecord
    self.table_name = "seo_sites"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :seo_sites
    belongs_to :environment, class_name: "Types::Environment", inverse_of: :seo_sites
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    has_many :audits, class_name: "Seo::Audit", foreign_key: :site_id, inverse_of: :site,
             dependent: :destroy
    has_many :pages, class_name: "Seo::Page", foreign_key: :site_id, inverse_of: :site,
             dependent: :destroy
    has_many :issues, class_name: "Seo::Issue", foreign_key: :site_id, inverse_of: :site,
             dependent: :destroy
    has_many :lab_runs, class_name: "Seo::LabRun", foreign_key: :site_id, inverse_of: :site,
             dependent: :destroy

    # Ogni quanto rivisitare. Workflow tecnico scelto dall'utente fra due valori → enum legittimo
    # (rules/lookup-tables.md). Giornaliero è il default: un `noindex` finito in produzione per
    # sbaglio non deve restare invisibile per una settimana.
    enum :frequency, { daily: 0, weekly: 1 }, prefix: :every

    INTERVALS = { "daily" => 1.day, "weekly" => 7.days }.freeze

    # Tetto massimo consentito, oltre il quale non si va nemmeno chiedendolo: un giro da diecimila
    # pagine è una visita ostile al sito di qualcun altro, e occuperebbe la coda per ore.
    MAX_PAGES_CEILING = 1_000

    normalizes :base_url, with: ->(value) { value.to_s.strip.chomp("/") }

    validates :base_url, presence: true, format: { with: %r{\Ahttps?://[^\s/]+.*\z}i }
    validates :max_pages, numericality: {
      only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_PAGES_CEILING
    }
    validates :environment_id, uniqueness: { scope: :project_id, message: :site_exists }
    # Host palesemente interno (IP privato scritto per esteso, localhost): si blocca subito, in
    # faccia a chi compila il form. Il controllo COMPLETO — con risoluzione DNS e IP pinnato sulla
    # connessione — resta nel crawler, che è l'unico posto dove conta davvero: un dominio pubblico
    # oggi può puntare a 10.0.0.1 domani, e una validazione al salvataggio non lo vedrebbe mai.
    validate :base_url_host_not_obviously_internal
    validate :environment_declared_by_project
    # Requisito di AMMISSIONE, non invariante perpetuo (stessa scelta di Uptime::Monitor, e per la
    # stessa ragione: ogni giro salva il sito per aggiornare `last_audited_at`, e una validazione
    # viva sull'update farebbe fallire la transazione lasciando il cockpit fermo in silenzio).
    validate :project_has_a_web_platform, on: :create

    scope :enabled, -> { where(enabled: true) }
    scope :ordered, -> { order(:base_url) }
    # Siti scaduti da rivisitare: attivi, mai visitati o con la scadenza già passata.
    # `now` come bind → testabile con travel_to.
    scope :due, lambda { |now = Time.current|
      enabled.where("next_audit_at IS NULL OR next_audit_at <= ?", now)
    }

    # Chi è maturo per una nuova misura di velocità. Scadenza separata da quella della visita
    # (CYRA-539): le due cose falliscono per ragioni diverse e non devono trascinarsi a vicenda.
    scope :due_for_lab_run, lambda { |now = Time.current|
      enabled.where("next_lab_run_at IS NULL OR next_lab_run_at <= ?", now)
    }

    def interval = INTERVALS.fetch(frequency, 1.day)

    # Prossima scadenza a partire da un istante: la calcola chi chiude il giro.
    def next_audit_after(instant = Time.current) = instant + interval

    # La misura di velocità segue la stessa frequenza scelta per la visita: un solo concetto di
    # «ogni quanto» da spiegare a chi configura il sito. La SCADENZA invece è su una colonna sua
    # (CYRA-539), perché un 429 di Google non deve ritardare il crawl delle pagine.
    def next_lab_run_after(instant = Time.current) = instant + interval

    def host
      URI.parse(base_url).host
    rescue URI::InvalidURIError
      nil
    end

    def display_name = "#{project.name} · #{environment.label}"

    def open_issues_count = issues.status_open.count

    private

    def base_url_host_not_obviously_internal
      return if base_url.blank?

      host = begin
        URI.parse(base_url).host
      rescue URI::InvalidURIError
        nil
      end
      return errors.add(:base_url, :invalid) if host.blank?
      # Solo il caso senza DNS: un IP scritto a mano dentro un intervallo privato, o un nome che
      # non esce dalla macchina. Tutto il resto lo decide NetworkGuard al momento del fetch.
      return unless NetworkGuard.ip_literal?(host) ? NetworkGuard.blocked_address?(host) : local_hostname?(host)

      errors.add(:base_url, :internal_host)
    end

    LOCAL_HOSTNAMES = %w[localhost].freeze

    def local_hostname?(host)
      normalized = host.downcase
      LOCAL_HOSTNAMES.include?(normalized) || normalized.end_with?(".localhost", ".local", ".internal")
    end

    def environment_declared_by_project
      return if project.blank? || environment.blank?
      return if project.environments.exists?(id: environment_id)

      errors.add(:environment_id, :not_declared_by_project)
    end

    def project_has_a_web_platform
      return if project.blank?
      return if Projects::Project.analytics_capable.exists?(id: project_id)

      errors.add(:project_id, :no_web_platform)
    end
  end
end
