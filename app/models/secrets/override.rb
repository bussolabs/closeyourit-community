# frozen_string_literal: true

module Secrets
  # Override PERSONALE del valore di un secret di progetto (CYRA-79). Una riga dice: «per QUESTA
  # persona, su questo progetto e ambiente, NAME vale questo» — e vince sul default del vault
  # (Secrets::Variable) quando il bundle è risolto PER un account. Può anche aggiungere una variabile
  # che nei default non esiste: è comunque una deviazione locale di chi la riceve, non una seconda
  # fonte di verità.
  #
  # admin-provisioned: la scrittura passa solo da Secrets::Overrides::Set/Delete (gate secrets.manage),
  # mai dall'interessato. Nessun versioning e nessuna rotazione: lo storico e le policy restano sulla
  # variabile di progetto, che l'override non tocca.
  #
  # NON esce MAI verso una macchina: Secrets::Github::Preflight risolve il bundle con `account: nil`,
  # quindi il push su GitHub porta sempre e solo i default (spec di guardia sul payload).
  class Override < ApplicationRecord
    belongs_to :account, class_name: "Accounts::Account"
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project", inverse_of: :secret_overrides
    belongs_to :environment, class_name: "Types::Environment"
    # L'admin che l'ha assegnato: nullify alla sua cancellazione — l'override sopravvive a chi lo crea,
    # altrimenti si spegnerebbe l'ambiente di lavoro di qualcun altro.
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    # Destinatario/progetto/ambiente/org sono l'identità: si sposta un override cancellandolo e
    # ricreandolo, mai riassegnandolo (stessa regola di Secrets::Variable: niente leak cross-scope
    # silenziosi).
    attr_readonly :account_id, :project_id, :environment_id, :organization_id

    encrypts :value

    normalizes :name, with: ->(name) { name.to_s.strip.upcase }
    normalizes :description, with: ->(value) { value.to_s.strip }

    # Le regole del NOME sono quelle del vault (Secrets::Variable): un override deve poter sostituire
    # un default, quindi deve poter portare esattamente gli stessi nomi — né di più né di meno.
    validates :name, presence: true,
              format: { with: ::Secrets::Variable::NAME_FORMAT },
              uniqueness: { scope: %i[account_id project_id environment_id] }
    validate :value_not_null
    validate :name_not_reserved
    validate :environment_declared_by_project
    validate :organization_matches_project
    validate :account_member_of_organization

    scope :ordered, -> { order(:name) }
    # Gli override che valgono per una lettura: [destinatario, progetto, ambiente]. Consumato da
    # Secrets::Bundle.
    scope :for_read, lambda { |account:, project:, environment:|
      where(account_id: account, project_id: project, environment_id: environment)
    }

    private

    # `nil` è un valore non fornito; `""` è distinto e intenzionale (opzione che deve esistere come ENV
    # ma può essere disattivata) — identico a Secrets::Variable.
    def value_not_null
      errors.add(:value, :blank) if value.nil?
    end

    def name_not_reserved
      return if name.blank?

      errors.add(:name, :reserved_prefix) if name.start_with?(::Secrets::Variable::RESERVED_NAME_PREFIX)
      errors.add(:name, :reserved) if ::Secrets::Variable::DERIVED_NAMES.include?(name)
      errors.add(:name, :reserved_runtime) if ::Secrets::Variable.reserved_runtime_name?(name)
    end

    # L'environment dev'essere DICHIARATO dal progetto (subset), come per Secrets::Variable.
    def environment_declared_by_project
      return if project.blank? || environment.blank?

      errors.add(:environment, :invalid) unless project.environment_ids.include?(environment_id)
    end

    # Integrità tenant: la org denormalizzata deve combaciare con quella del progetto.
    def organization_matches_project
      return if project.blank?

      errors.add(:organization_id, :invalid) if organization_id != project.organization_id
    end

    # Tenant guard sul DESTINATARIO: assegnare un override a chi non appartiene all'organizzazione del
    # progetto lascerebbe una riga viva su un account estraneo. Il vincolo più stretto — «deve poter
    # leggere QUESTI secret» — vive in Secrets::Overrides::Set, che è l'unico punto di scrittura.
    def account_member_of_organization
      return if project.blank? || account_id.blank?

      member = Connections::Membership.exists?(account_id: account_id, organization_id: project.organization_id)
      errors.add(:account, :invalid) unless member
    end
  end
end
