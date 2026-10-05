# frozen_string_literal: true

module Secrets
  # Variabile d'ambiente cifrata del vault, scoped a [progetto, ambiente]. Fonte canonica:
  # una riga per nome. Il valore è cifrato at-rest (ActiveRecord::Encryption, non-deterministico:
  # non si interroga mai per valore) e decifrato lato server solo su richiesta autorizzata
  # (gate `secrets.read`). La generazione/upsert vive nei service Secrets::Variables::* (mai callback).
  #
  # Rotazione "morbida" (CYRA-138, Fase 4 pezzo A1): `rotation_interval_days` (nil default) è una
  # policy opt-in "ruota ogni N giorni"; `rotated_at` è l'ultima volta che il VALORE è cambiato
  # (mantenuto da Secrets::Variables::Set, MAI da un callback qui). La scadenza (#rotate_by) è SOLO un
  # avviso: il segreto resta SEMPRE valido e leggibile, Secrets::Bundle e il flusso di lettura non
  # sanno nulla di questi due campi. Si "ri-arma" da sola alla prossima rotazione, riusando il fatto
  # che il valore è cambiato — nessun job/reset esplicito.
  class Variable < ApplicationRecord
    # Nome in stile ENV: UPPER_SNAKE, deve iniziare con lettera o underscore.
    NAME_FORMAT = /\A[A-Z_][A-Z0-9_]*\z/
    # GitHub Actions rifiuta i secret con questo prefisso (vincolo già noto al progetto, vedi la
    # decisione GitHub 2026-07-07): lo blocchiamo a monte così il sync futuro non fallisce.
    RESERVED_NAME_PREFIX = "GITHUB_"
    # Bundle calcolati al momento del sync GitHub: non devono mai diventare fonte di verità nel vault.
    DERIVED_NAMES = %w[SECRETS_JSON KAMAL_SECRETS_JSON].freeze
    # Soglia di preavviso della rotazione: entro questa finestra da #rotate_by lo stato passa a
    # :due_soon (vedi #rotation_status). App::Constants perché affianca le altre soglie/retention
    # cross-dominio (SOURCE_FRESH_WITHIN, LOGS_RETENTION_DEFAULT_DAYS, ...).
    ROTATION_DUE_SOON_THRESHOLD = Secrets::Constants::ROTATION_DUE_SOON_DAYS.days

    belongs_to :organization,
               class_name: "Organizations::Organization"
    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :secret_variables
    belongs_to :environment,
               class_name: "Types::Environment",
               inverse_of: :secret_variables
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    # Storico immutabile dei valori (versioning + rollback). Cascade via FK on_delete.
    has_many :versions,
             class_name: "Secrets::Version",
             foreign_key: :secret_variable_id,
             inverse_of: :secret_variable,
             dependent: :destroy
    has_many :provisions,
             class_name: "Secrets::Provision",
             foreign_key: :secret_variable_id,
             dependent: :destroy

    # Progetto/ambiente/org sono l'identità: si sposta un secret cancellandolo e ricreandolo, mai
    # riassegnandolo (evita leak cross-scope silenziosi).
    attr_readonly :project_id, :environment_id, :organization_id

    encrypts :value

    normalizes :name, with: ->(name) { name.to_s.strip.upcase }
    normalizes :description, with: ->(value) { value.to_s.strip }

    validates :name, presence: true,
              format: { with: NAME_FORMAT },
              uniqueness: { scope: %i[project_id environment_id] }
    validate :value_not_null
    validate :name_not_reserved
    validate :environment_declared_by_project
    validate :organization_matches_project
    # Capability per-ambiente: i secret devono essere abilitati (risolto default+override) su [progetto,
    # ambiente]. Solo alla creazione: disabilitare la capability DOPO non invalida i secret esistenti né
    # ne blocca l'aggiornamento (upsert su record esistente = update).
    validate :secrets_capability_enabled, on: :create
    validate :no_shared_delegation_conflict, on: :create
    # nil = nessuna policy (default); impostata solo dall'azione dedicata (Member::ProjectSecretsController
    # #rotation), mai da Secrets::Variables::Set.
    validates :rotation_interval_days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    # Impronta del valore (CYRA-777): l'unico modo di riconoscere lo stesso segreto in due progetti
    # senza decifrare niente. È un callback, e qui è la scelta giusta anche se `rotated_at` poco sopra
    # dice l'opposto: `rotated_at` è una DECISIONE («questo cambio conta come rotazione») e sta nel
    # service, l'impronta è una FUNZIONE PURA del valore. Se si desincronizza — un solo percorso di
    # scrittura che si dimentica di aggiornarla — il prodotto propone di consolidare valori che non
    # sono più uguali, e lo fa in silenzio.
    before_save :assign_value_fingerprint

    scope :ordered, -> { order(:name) }
    # Variabili con una policy di rotazione attiva (interval presente), a prescindere dallo stato.
    scope :with_rotation_policy, -> { where.not(rotation_interval_days: nil) }
    # Variabili la cui scadenza (rotate_by) è già nella finestra di preavviso o superata: :due_soon +
    # :overdue, MAI :ok/:none. Calcolato in SQL (rotated_at + N giorni, cast esplicito integer→text→
    # interval: Postgres non concatena `||` tra integer e text senza cast) così è utilizzabile come
    # scope componibile; Secrets::RotationReport (vista org-wide) precarica comunque in blocco e
    # ricalcola rotation_status in Ruby, per restare sullo stesso pattern di Secrets::HealthCheck.
    scope :due_for_rotation, lambda {
      with_rotation_policy.where(
        "rotated_at IS NOT NULL AND rotated_at + (rotation_interval_days::text || ' days')::interval <= ?",
        Time.current + ROTATION_DUE_SOON_THRESHOLD
      )
    }

    # Prossima scadenza "morbida" della policy di rotazione (rotated_at + rotation_interval_days
    # giorni). nil se manca la policy o rotated_at (variabile mai passata da Secrets::Variables::Set,
    # es. fixture/import diretto in test) — in quel caso #rotation_status è :none, mai un errore.
    def rotate_by
      return nil if rotation_interval_days.blank? || rotated_at.blank?

      rotated_at + rotation_interval_days.days
    end

    # Stato della scadenza — SEMPRE e solo un avviso, non blocca mai la lettura del segreto:
    # :none    nessuna policy di rotazione (o rotated_at mancante)
    # :ok      rotate_by oltre la soglia di preavviso
    # :due_soon rotate_by entro la soglia di preavviso ma non ancora passata
    # :overdue rotate_by già nel passato
    def rotation_status
      due = rotate_by
      return :none if due.nil?
      return :overdue if due < Time.current
      return :due_soon if due <= Time.current + ROTATION_DUE_SOON_THRESHOLD

      :ok
    end

    # Giorni interi tra ora e rotate_by, su base di calendario (positivo = ancora da venire, negativo
    # = già superato); nil senza policy. Solo per il display badge/report — #rotation_status resta la
    # fonte di verità dello stato.
    def rotation_days_until_due
      due = rotate_by
      return nil if due.nil?

      (due.to_date - Time.current.to_date).to_i
    end

    private

    # nil quando il valore non va confrontato con nessuno (assente, vuoto, troppo corto): la colonna
    # torna nulla e la riga esce dai raggruppamenti, che è esattamente ciò che deve succedere.
    def assign_value_fingerprint
      self.value_fingerprint = ::Secrets::Consolidation::Fingerprint.for(value)
    end

    # `nil` significa valore non fornito/corrotto. `""` è distinto e intenzionale: serve per opzioni
    # che devono esistere come ENV ma possono essere disabilitate (es. liste destinatari vuote).
    def value_not_null
      errors.add(:value, :blank) if value.nil?
    end

    def name_not_reserved
      return if name.blank?

      errors.add(:name, :reserved_prefix) if name.start_with?(RESERVED_NAME_PREFIX)
      errors.add(:name, :reserved) if DERIVED_NAMES.include?(name)
    end

    # L'environment dev'essere DICHIARATO dal progetto (subset), come per Projects::Token.
    def environment_declared_by_project
      return if project.blank? || environment.blank?

      errors.add(:environment, :invalid) unless project.environment_ids.include?(environment_id)
    end

    # Integrità tenant: la org denormalizzata deve combaciare con quella del progetto.
    def organization_matches_project
      return if project.blank?

      errors.add(:organization_id, :invalid) if organization_id != project.organization_id
    end

    # Flag RISOLTO (default ambiente + eventuale override progetto) dalla riga join, garantita al create
    # da environment_declared_by_project (no-op se assente).
    def secrets_capability_enabled
      return if project.blank? || environment.blank?

      link = project.project_environments.find_by(environment_id: environment_id)
      errors.add(:base, :secrets_disabled) if link && !link.secrets_enabled?
    end

    def no_shared_delegation_conflict
      return if project.blank? || environment.blank? || name.blank?

      # CYRA-777 — si confronta col nome EFFETTIVO della delega (l'alias del progetto quando c'è):
      # è quello che finirebbe nel bundle accanto a questa variabile, ed è lì che i due si
      # sovrascriverebbero a vicenda. Guardare il nome del secret dell'organizzazione lascerebbe
      # passare la collisione vera e ne inventerebbe una che non esiste.
      conflict = ::Secrets::Shared::Delegation.joins(:shared_value)
        .where(project_id:, secrets_shared_values: { environment_id: })
        .joins("INNER JOIN secrets_shared_variables ON secrets_shared_variables.id = secrets_shared_values.shared_variable_id")
        .where("COALESCE(secrets_shared_delegations.local_name, secrets_shared_variables.name) = ?", name).exists?
      errors.add(:name, :shared_secret_conflict) if conflict
    end
  end
end
