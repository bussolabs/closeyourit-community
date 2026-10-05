module Accounts
  # Token a livello UTENTE per la CLI (account-proxy). Autentica COME l'account: il concern
  # UserTokenAuthentication pinna Current.account + Current.organization, e ogni azione passa per
  # Authorization::Resolver (permessi LIVE dell'account). Distinto dai Projects::Token (ingest macchina,
  # prefisso "cyi_") dal prefisso "cyi_u_". La generazione del segreto vive in Accounts::ApiTokens::Issue
  # (mai in callback) — qui solo persistenza. In DB solo `token_digest` = SHA-256 (segreto full-entropy).
  class ApiToken < ApplicationRecord
    # Il namespace Accounts non ha table_name_prefix (Accounts::Account → "accounts"); nome esplicito.
    self.table_name = "accounts_api_tokens"

    # Soglia di preavviso della scadenza (CYRA-717): entro questa finestra da expires_at lo stato
    # passa a :due_soon, e la riga di comando lo ricorda a ogni chiamata. Vive in App::Constants
    # accanto alle altre soglie cross-dominio.
    EXPIRY_DUE_SOON_THRESHOLD = Accounts::Constants::API_TOKEN_EXPIRY_DUE_SOON_DAYS.days

    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :api_tokens
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :api_tokens
    has_many :device_grants,
             class_name: "Accounts::DeviceGrant",
             foreign_key: :api_token_id,
             inverse_of: :api_token,
             dependent: :nullify

    validates :name, presence: true
    validates :token_digest, presence: true, uniqueness: true
    validates :token_prefix, presence: true
    # Integrità tenant: l'account dev'essere membro dell'org per cui il token è emesso (anti-BOLA a monte).
    validate :account_is_member_of_organization
    # Solo alla CREAZIONE (CYRA-717): un token che nasce già scaduto è un errore di digitazione, mai
    # un'intenzione. Dopo, la data resta com'è — un token arrivato a scadenza deve restare
    # aggiornabile (last_used_at sull'hot path, revoca) senza che la validazione lo immobilizzi.
    validate :expires_at_in_future, on: :create

    # Token utilizzabile: non revocato E non scaduto (scadenza opzionale).
    scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

    def revoked? = revoked_at.present?

    # Scaduto = l'istante di scadenza è arrivato. Nessuna tolleranza: il confine è `<=`, lo stesso di
    # .active (che tiene solo `expires_at > now`), così scope e predicato non possono dare risposte
    # diverse sullo stesso token nello stesso istante.
    def expired?(at: Time.current) = expires_at.present? && expires_at <= at

    # Stato della scadenza per la pagina token e per la riga di comando (CYRA-717):
    #   :none     nessuna scadenza (service account, e tutti i token emessi prima di CYRA-717)
    #   :ok       scadenza oltre la finestra di preavviso
    #   :due_soon scadenza dentro la finestra di preavviso, non ancora passata
    #   :expired  scadenza superata — il token NON autentica più
    def expiry_status(at: Time.current)
      return :none if expires_at.blank?
      return :expired if expires_at <= at
      return :due_soon if expires_at <= at + EXPIRY_DUE_SOON_THRESHOLD

      :ok
    end

    # Giorni interi tra oggi e la scadenza, su base di calendario (positivo = ancora da venire,
    # negativo = già superata); nil senza scadenza. Solo per il display — #expiry_status resta la
    # fonte di verità dello stato.
    def days_until_expiry(at: Time.current)
      return nil if expires_at.blank?

      (expires_at.to_date - at.to_date).to_i
    end

    # Debounce dell'aggiornamento di last_used_at (non scrivere a ogni richiesta CLI).
    def stale_usage?(threshold: 1.minute)
      last_used_at.nil? || last_used_at < threshold.ago
    end

    private

    def account_is_member_of_organization
      return if account_id.blank? || organization_id.blank?
      return if Connections::Membership.exists?(account_id:, organization_id:)

      errors.add(:account, :not_a_member)
    end

    def expires_at_in_future
      return if expires_at.blank? || expires_at > Time.current

      errors.add(:expires_at, :must_be_in_future)
    end
  end
end
