# frozen_string_literal: true

module Secrets
  module Personal
    # Variabile d'ambiente cifrata del vault PERSONALE, scoped a [account, organization] — gemello per-utente
    # di Secrets::Variable (che è per [progetto, ambiente]). Struttura FLAT: un unico set { nome => valore }
    # per utente, senza ambienti. Il valore è cifrato at-rest (ActiveRecord::Encryption, non-deterministico:
    # non si interroga mai per valore) e decifrato lato server solo per l'account proprietario. L'account è la
    # radice di tenancy E l'unico attore → nessuna colonna created_by, nessun RBAC (ownership come Todos::List),
    # nessun sync GitHub. La generazione/upsert vive nei service Secrets::Personal::Variables::* (mai callback).
    class Variable < ApplicationRecord
      # Nome in stile ENV: UPPER_SNAKE, deve iniziare con lettera o underscore.
      NAME_FORMAT = /\A[A-Z_][A-Z0-9_]*\z/

      belongs_to :account, class_name: "Accounts::Account"
      belongs_to :organization, class_name: "Organizations::Organization"

      # Storico immutabile dei valori (versioning + rollback). Cascade via FK on_delete.
      has_many :versions,
               class_name: "Secrets::Personal::Version",
               foreign_key: :variable_id,
               inverse_of: :variable,
               dependent: :destroy

      # Account/org sono l'identità: un secret si sposta cancellandolo e ricreandolo, mai riassegnandolo
      # (evita leak cross-scope silenziosi).
      attr_readonly :account_id, :organization_id

      encrypts :value

      normalizes :name, with: ->(name) { name.to_s.strip.upcase }
      normalizes :description, with: ->(value) { value.to_s.strip }

      validates :name, presence: true,
                format: { with: NAME_FORMAT, message: ->(*) { I18n.t("member.review_fixes.secret_name_hint") } },
                uniqueness: { scope: %i[account_id organization_id] }

      scope :ordered, -> { order(:name) }

      # Secret dell'account nell'org (posseduti). Anti-BOLA per find/destroy.
      def self.for(account:, organization:)
        where(account_id: account.id, organization_id: organization.id)
      end
    end
  end
end
