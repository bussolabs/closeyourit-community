module Projects
  # Credenziale di ingest per-progetto. Due rappresentazioni dello stesso token:
  #   - bearer secret (CI / read API): segreto vero, mostrato UNA volta alla creazione; in DB solo
  #     `token_digest` = SHA-256 (lookup O(1) sull'hot path; non bcrypt: il segreto è full-entropy).
  #   - DSN public key (ingest Sentry): per design NON segreta, viaggia negli SDK; lookup diretto.
  # La generazione del segreto vive in Projects::Tokens::Issue (mai in callback) — qui solo persistenza.
  class Token < ApplicationRecord
    # Il namespace Projects non ha table_name_prefix (Projects::Project → "projects"); fissiamo il
    # nome esplicito (come Projects::Group).
    self.table_name = "projects_tokens"

    # Soglia di preavviso della scadenza (CYRA-716): entro questa finestra da expires_at lo stato
    # passa a :due_soon e il giro giornaliero manda il promemoria. Vive in App::Constants accanto
    # alle altre soglie cross-dominio.
    EXPIRY_DUE_SOON_THRESHOLD = Projects::Constants::TOKEN_EXPIRY_DUE_SOON_DAYS.days

    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :tokens
    belongs_to :environment,
               class_name: "Types::Environment",
               inverse_of: :tokens
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    has_many :secret_provisions,
             class_name: "Secrets::Provision",
             foreign_key: :token_id,
             dependent: :destroy

    validates :name, presence: true
    validates :token_digest, presence: true, uniqueness: true
    validates :token_prefix, presence: true
    validates :public_key, presence: true, uniqueness: true
    # L'environment del token dev'essere DICHIARATO dal progetto (subset), come ticket-platform ⊆ project-platform.
    validate :environment_declared_by_project
    # Solo alla CREAZIONE: un token che nasce già scaduto è un errore di digitazione, mai un'intenzione.
    # Dopo, la data resta com'è — un token arrivato a scadenza deve poter essere aggiornato (last_used_at
    # sull'hot path, revoca) senza che la validazione lo renda immodificabile.
    validate :expires_at_in_future, on: :create

    # Credenziali che AUTENTICANO davvero: né revocate né scadute (CYRA-716). È l'unico scope usato
    # dalla risoluzione del bearer e della DSN, quindi la scadenza spegne l'ingest da sola. expires_at
    # NULL = nessuna scadenza (tutti i token emessi prima di CYRA-716): restano validi per sempre,
    # spegnerli d'ufficio avrebbe fermato gli SDK di chi non ha fatto niente.
    scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
    scope :with_expiry, -> { where.not(expires_at: nil) }
    # Token da segnalare nel giro del promemoria: scadenza dentro la finestra di preavviso o GIÀ
    # superata, revocati esclusi (un token revocato non interessa più a nessuno). Gli scaduti restano
    # dentro di proposito: la scadenza mancata è la notizia più importante delle due, e l'avviso non
    # si ripete perché il dedup_key è ancorato a (token, scadenza), non alla data odierna.
    scope :due_for_expiry, lambda {
      where(revoked_at: nil).with_expiry.where(expires_at: ..(Time.current + EXPIRY_DUE_SOON_THRESHOLD))
    }

    def revoked? = revoked_at.present?

    # Scaduto = l'istante di scadenza è arrivato. Nessuna finestra di tolleranza: il confine è `<=`,
    # lo stesso di .active (che tiene solo `expires_at > now`), così scope e predicato non possono
    # dare risposte diverse sullo stesso token nello stesso istante.
    def expired?(at: Time.current) = expires_at.present? && expires_at <= at

    # Stato della scadenza per la UI e per il promemoria:
    #   :none     nessuna scadenza impostata (il token vale finché non lo si revoca)
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

    # Scope del token (ingest vs read). Un bearer cyi_ SERVER-ONLY porta piena potenza (ingest+read);
    # un token ristretto (es. ingest-only browser-safe) NON deve leggere la telemetria. L'enforcement
    # vive in TokenAuthentication#require_scope!. Vedi decisions/2026-07-09-cyi-token-server-only.
    def scope?(name) = scopes.include?(name.to_s)

    # DSN Sentry-style: gli SDK puntano qui cambiando solo SENTRY_DSN.
    def to_dsn(host:) = "https://#{public_key}@#{host}/#{project_id}"

    def to_sentry_dsn(host:)
      identifier = project.sentry_project_id || project.reload.sentry_project_id
      "https://#{public_key}@#{host}/#{identifier}"
    end

    # Debounce dell'aggiornamento di last_used_at (non bloccare l'ingest con una write a ogni richiesta).
    def stale_usage?(threshold: 1.minute)
      last_used_at.nil? || last_used_at < threshold.ago
    end

    private

    def environment_declared_by_project
      return if project.blank? || environment.blank?

      errors.add(:environment, :invalid) unless project.environment_ids.include?(environment_id)
    end

    def expires_at_in_future
      return if expires_at.blank? || expires_at > Time.current

      errors.add(:expires_at, :must_be_in_future)
    end
  end
end
