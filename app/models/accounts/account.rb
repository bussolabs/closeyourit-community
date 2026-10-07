module Accounts
  class Account < ApplicationRecord
    has_secure_password

    # 2FA TOTP (CYRA-170): il seme è cifrato at-rest (ActiveRecord::Encryption non-deterministico, come
    # Secrets::Variable#value — mai interrogato per valore). otp_enabled_at è la sorgente di #otp_enabled?.
    encrypts :otp_secret

    # human (default): utente reale che fa login web/password. service: account NON-umano (agente AI),
    # CLI-only — non fa login web (rifiutato in Auth::SessionsController) e ottiene solo token cyi_u_
    # (account-proxy) coniati dall'owner. Creato da Accounts::Service::Create con email sintetica +
    # password random. Si limita come un umano via RBAC (ruoli + visibilità per-progetto).
    enum :kind, { human: 0, service: 1 }, default: :human

    # Preferenze utente (jsonb). projects_view = modalità lista progetti scelta personalmente
    # (cards/table); nil → si ricade sul default org, poi su "cards". Vedi OrganizationContext.
    # platform_codes = codici piattaforma che l'utente usa (globali, match per code cross-org):
    # pre-selezionano le piattaforme alla creazione ticket. Vedi Types::Platform.
    # locale = lingua dell'interfaccia area member (en/it); nil → default I18n (en). Vedi
    # Member::BaseController#switch_locale.
    # telegram_project_id = progetto "attivo" scelto da Telegram (/progetto CHIAVE): default per
    # /nuovo-ticket senza chiave. La visibilità è SEMPRE ri-verificata al momento dell'uso
    # (Telegram::ResolveProject) → un progetto non più visibile viene ignorato, nessun leak.
    # board_collapsed_statuses = codici degli status ridotti (collassati) nella board dei ticket
    # (CYRA-390): la scelta di chiudere una colonna è personale e ricordata alla visita successiva.
    # Per code e non per id: il code è stabile e leggibile, e "colonne concluse chiuse" trasferisce
    # sensatamente tra le org dell'utente. Vedi Member::Tickets::CollapsedColumnsController.
    # page_header_compact = the page header collapsed on every member page (DESIGN.md B25).
    # dismissed_notices = keys of the floating notices the person closed (Ui::FloatingNoticeComponent).
    # theme = light, dark or system (DESIGN.md A32); blank means light.
    store_accessor :preferences, :projects_view, :platform_codes, :locale, :telegram_project_id, :telegram_puck_id,
                   :board_collapsed_statuses, :page_header_compact, :dismissed_notices, :theme

    def page_header_compact?
      ActiveModel::Type::Boolean.new.cast(page_header_compact) || false
    end

    def dismissed_notices
      Array(super)
    end

    def notice_dismissed?(key)
      dismissed_notices.include?(key.to_s)
    end

    # Colonne board collassate: SEMPRE una lista (mai nil), così la view può interrogarla senza
    # guardie. Il setter normalizza — scarta i vuoti, deduplica, porta uno scalare a lista — perché
    # la sorgente è un accessor store (l'Attribute API di `normalizes` non lo intercetta, stesso
    # motivo per cui `normalizes` non basta: gli accessor di store_accessor leggono e scrivono
    # preferences[...] senza passare dall'Attribute API che `normalizes` decora). Nessuna validazione
    # del code contro gli status: è una preferenza
    # UI, un code stantìo non corrisponde a nessuna colonna e viene semplicemente ignorato.
    def board_collapsed_statuses
      Array(super)
    end

    def board_collapsed_statuses=(value)
      super(Array(value).map { |code| code.to_s.strip }.reject(&:blank?).uniq)
    end

    # La board è già stata configurata almeno una volta? Finché no, le colonne CONCLUSE partono
    # ridotte (default che fa stare tutte le colonne su uno schermo da 13" senza scorrere di lato);
    # dal primo tocco comanda la lista esplicita. Distinto dal getter — che appiattisce nil e [] a [] —
    # perché qui serve sapere se la CHIAVE esiste, non se la lista è vuota.
    def board_columns_configured?
      preferences.key?("board_collapsed_statuses")
    end

    # Token di reset password a scadenza breve; invalidato al cambio password
    # (il digest cambia → cambia il seed del token). Vedi rules/authorization.md.
    generates_token_for :password_reset, expires_in: Accounts::Constants::TTL_PASSWORD_RESET do
      password_digest&.last(10)
    end

    # Pending del secondo fattore (CYRA-170 FIX-4): dopo la password ma prima del 2FA. Legato alla
    # versione della password (password_salt) così un reset password — che revoca le sessioni (FIX B) —
    # invalida anche una challenge 2FA in volo: chi aveva superato la VECCHIA password non può più
    # completare il secondo fattore. Il token porta la scadenza (OTP_PENDING_TTL) → find_by_token_for
    # ritorna nil se scaduto O se la password è cambiata (niente timestamp manuale da gestire).
    generates_token_for :two_factor_login, expires_in: Accounts::Constants::OTP_PENDING_TTL do
      password_salt&.last(10)
    end

    has_many :sessions,
             class_name: "Accounts::Session",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # Codici di recupero 2FA monouso (CYRA-170): posseduti dall'account → cadono con esso
    # (FK on_delete: :cascade ⇄ dependent: :destroy). disable_otp! li azzera comunque.
    has_many :otp_recovery_codes,
             class_name: "Accounts::OtpRecoveryCode",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # Codici corti monouso del deep-link /start Telegram (rimpiazzano il token firmato: 238 char non
    # entrano nel parametro `start` di Telegram, max 64). Consumati al collegamento; FK on_delete cascade.
    has_many :telegram_link_codes,
             class_name: "Accounts::TelegramLinkCode",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    has_many :memberships,
             class_name: "Connections::Membership",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :organizations,
             through: :memberships,
             source: :organization

    has_many :group_memberships,
             class_name: "Connections::GroupMembership",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :accessible_groups, through: :group_memberships, source: :group

    has_many :project_memberships,
             class_name: "Connections::ProjectMembership",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :directly_accessible_projects, through: :project_memberships, source: :project

    # CYRA-654 — i «non oggi» di questa persona sulla coda delle decisioni della home. Cadono con
    # l'account (FK on_delete: :cascade ⇄ dependent: :destroy): sono una preferenza di lettura, non
    # un dato che qualcun altro debba ritrovare.
    has_many :home_deferrals,
             class_name: "Home::Deferral",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # RBAC: appartenenza a team + ruoli diretti + override personali. Soggetto della relazione →
    # alla cancellazione dell'account spariscono (dependent: :destroy, allineato a FK on_delete: cascade).
    has_many :team_memberships,
             class_name: "Connections::TeamMembership",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :teams, through: :team_memberships, source: :team
    # Partecipazioni alle workload actions (attività non-dev dei team). Soggetto → destroy.
    has_many :workload_participations,
             class_name: "Connections::WorkloadParticipant",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :workload_actions, through: :workload_participations, source: :action
    has_many :account_roles,
             class_name: "Authorization::AccountRole",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :assigned_roles, through: :account_roles, source: :role
    has_many :account_permissions,
             class_name: "Authorization::AccountPermission",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # Token CLI a livello utente (account-proxy) + concessioni device-flow: soggetti dell'account →
    # cadono con esso (FK on_delete: :cascade, allineato a dependent: :destroy).
    has_many :api_tokens,
             class_name: "Accounts::ApiToken",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :device_grants,
             class_name: "Accounts::DeviceGrant",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # Liste di todo personali possedute dall'account + condivisioni ricevute (sola lettura). Dati
    # posseduti dall'utente (FK on_delete: :cascade ⇄ dependent: :destroy): cadono con l'account.
    has_many :todo_lists,
             class_name: "Todos::List",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :todo_shares,
             class_name: "Todos::Share",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :shared_todo_lists, through: :todo_shares, source: :list

    # Vault personale (secret cifrati per-utente, scoped [account, org]): dati posseduti dall'account
    # (FK on_delete: :cascade ⇄ dependent: :destroy). L'account È la radice E l'attore → l'audit personale
    # cade con lui (nessuna identità da preservare, a differenza di Secrets::Event.actor dei service account).
    has_many :personal_secret_variables,
             class_name: "Secrets::Personal::Variable",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :personal_secret_events,
             class_name: "Secrets::Personal::Event",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    # File segreti personali (CYRA-133): gemello per-file del vault personale. Stesso principio: l'account
    # è radice e attore → cade con lui (FK on_delete: :cascade ⇄ dependent: :destroy).
    has_many :personal_secret_assets,
             class_name: "Secrets::Personal::Asset",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :personal_secret_asset_events,
             class_name: "Secrets::Personal::AssetEvent",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # Richieste AI asincrone dell'account (draft effimeri, prunati da Ai::PruneRequestsJob).
    has_many :ai_requests,
             class_name: "Ai::Request",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    has_many :reported_tickets,
             class_name: "Ticketing::Ticket",
             foreign_key: :reporter_id,
             inverse_of: :reporter,
             dependent: :restrict_with_error
    has_many :assigned_tickets,
             class_name: "Ticketing::Ticket",
             foreign_key: :assignee_id,
             inverse_of: :assignee,
             dependent: :nullify
    # Gruppi d'errore assegnati (CYRA-153). La FK ha on_delete: :nullify a DB, dependent lo rispecchia.
    has_many :assigned_error_groups,
             class_name: "Errors::Group",
             foreign_key: :assignee_id,
             inverse_of: :assignee,
             dependent: :nullify
    has_many :reviewed_tickets,
             class_name: "Ticketing::Ticket",
             foreign_key: :reviewer_id,
             inverse_of: :reviewer,
             dependent: :nullify

    has_many :authored_comments,
             class_name: "Ticketing::Comment",
             foreign_key: :author_id,
             inverse_of: :author,
             dependent: :destroy

    # Voti (upvote) dati dall'account sui ticket. Il voto è opinione, non evidenza →
    # cade con l'account (FK on_delete: :cascade, AR dependent: :destroy).
    has_many :ticket_votes,
             class_name: "Connections::TicketVote",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # Idee proposte dall'account: metadato "creato da" → l'idea sopravvive all'account
    # (FK on_delete: :nullify), come created_by/invited_by.
    has_many :ideas,
             class_name: "Ideas::Idea",
             foreign_key: :author_id,
             inverse_of: :author,
             dependent: :nullify
    # Commenti alle idee: stessa policy di authored_comments (cadono con l'account).
    has_many :idea_comments,
             class_name: "Ideas::Comment",
             foreign_key: :author_id,
             inverse_of: :author,
             dependent: :destroy
    # Voti (upvote) dati dall'account sulle idee: opinione, non evidenza → cadono con l'account.
    has_many :idea_votes,
             class_name: "Connections::IdeaVote",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # Sottoscrizioni dell'account ai ticket (watcher): cadono con l'account (FK on_delete: :cascade).
    has_many :ticket_subscriptions,
             class_name: "Ticketing::Subscription",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy

    # Chat: lo stato di partecipazione cade con l'account (FK on_delete: :cascade); i messaggi
    # scritti sopravvivono con author a NULL (il thread non si spezza — FK on_delete: :nullify).
    has_many :chat_participations,
             class_name: "Chat::Participant",
             foreign_key: :account_id,
             inverse_of: :account,
             dependent: :destroy
    has_many :authored_chat_messages,
             class_name: "Chat::Message",
             foreign_key: :author_id,
             inverse_of: :author,
             dependent: :nullify

    # Eventi di cronologia in cui l'account è l'attore (percepito o reale). Alla cancellazione
    # dell'account l'evento sopravvive con actor/true_actor a NULL: lo snapshot `actor_name`
    # conserva chi era (audit veritiero). Allinea AR alla FK on_delete: :nullify.
    has_many :actor_events,
             class_name: "Ticketing::Event",
             foreign_key: :actor_id,
             inverse_of: :actor,
             dependent: :nullify
    has_many :true_actor_events,
             class_name: "Ticketing::Event",
             foreign_key: :true_actor_id,
             inverse_of: :true_actor,
             dependent: :nullify

    # Metadati "creato/invitato/impersonato da" (CYRA-746): qui NON c'è nessuna relazione, ed è
    # deliberato. Erano ventiquattro `has_many` verso ventiquattro aree — «i progetti che ho creato»,
    # «gli inviti che ho mandato» — che nessuna pagina e nessun service leggeva: l'unico compito era
    # il `dependent: :nullify`, cioè ripetere in Ruby quello che la chiave esterna fa già da sé
    # (`on_delete: :nullify` su tutte e ventiquattro le colonne, vedi db/schema.rb). La cancellazione
    # finisce identica — l'entità sopravvive e perde il riferimento all'attore — senza che l'account
    # debba elencare mezzo prodotto per ottenerla. Chi volesse davvero leggerne una la chiede a chi
    # la possiede: `Projects::Project.where(created_by: account)`. Rete:
    # spec/config/model_dependency_direction_spec.rb e la prova di cancellazione in
    # spec/requests/valhalla/accounts_spec.rb. I ticket segnalati (reported_tickets) restano invece
    # :restrict_with_error per scelta di dominio: un account con ticket aperti non si cancella.

    # Eventi di impersonation = audit di sicurezza (chi ha impersonato chi): NON vanno distrutti
    # alla cancellazione di un account (sarebbe evidence tampering). :restrict_with_error blocca
    # la destroy con errore gestito (alert pulito nel controller god), preservando l'evidenza.
    # Un account coinvolto in impersonation si cancella solo dopo aver gestito i suoi eventi.
    # Sono le uniche due sopravvissute alla potatura di CYRA-746 perché la loro chiave esterna non
    # porta `on_delete`: toglierle non lascerebbe il gate al database, lo trasformerebbe in
    # un'eccezione di chiave esterna — e questo lavoro non cambia comportamenti.
    has_many :impersonation_events_as_target, class_name: "Accounts::ImpersonationEvent",
             foreign_key: :account_id, dependent: :restrict_with_error
    has_many :impersonation_events_as_god, class_name: "Accounts::ImpersonationEvent",
             foreign_key: :god_id, dependent: :restrict_with_error

    normalizes :email, with: ->(email) { email.strip.downcase }
    normalizes :name, with: ->(name) { name.strip }
    normalizes :handle, with: ->(value) { value.to_s.strip.downcase }

    # Handle globale per le @menzioni nei commenti: [a-z0-9_], unico. Generato da ensure_handle quando
    # vuoto (nuovi account) a partire dalla parte locale dell'email; i record esistenti via migration.
    before_validation :ensure_handle

    validates :email, presence: true, uniqueness: true,
              format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :name, presence: true
    validates :projects_view, inclusion: { in: Projects::Constants::VIEWS }, allow_nil: true
    validates :theme, inclusion: { in: Accounts::Constants::THEMES }, allow_nil: true
    validates :locale, inclusion: { in: App::Constants::LOCALES }, allow_nil: true
    validates :handle, presence: true, uniqueness: true, format: { with: /\A[a-z0-9_]+\z/ }
    validate :password_complexity
    # I superadmin (god, area Valhalla) sono SEMPRE umani: un service account non può essere god.
    validate :god_reserved_for_humans

    # Vero se l'account è membro dell'org. Memoizzato sull'istanza (SOLO i true): le validazioni
    # tenant di più record creati per lo STESSO account (SetMemberAccess/SetAccountPermissions, o
    # fixture che collegano N progetti a un membro) interrogherebbero connections_memberships una
    # volta per record → stessa fingerprint ripetuta = prosopite N+1. Cache solo-positiva: un false
    # viene sempre ri-verificato (mai rigettare un create valido dopo che la membership è comparsa);
    # scoped all'oggetto → nessun leak cross-request.
    def member_of_organization?(organization_id)
      return false if organization_id.blank?

      @member_of_organization ||= {}
      key = organization_id.to_s
      return true if @member_of_organization[key]

      Connections::Membership.exists?(account_id: id, organization_id: organization_id).tap do |member|
        @member_of_organization[key] = true if member
      end
    end

    # Vero se l'account ha collegato il proprio Telegram (chat_id presente): condizione per ricevere
    # notifiche via DM del bot ufficiale. Nullo → la pagina preferenze mostra la guida di attivazione.
    def connected_telegram?
      telegram_chat_id.present?
    end

    # Locale effettivo per rendere testi nella lingua dell'utente: la preferenza `locale` se ammessa,
    # altrimenti il default I18n. Fonte unica del fallback, usata da controller (Localizable), mailer
    # (ApplicationMailer#mail) e pipeline notifiche/telegram (I18n.with_locale al momento dello snapshot).
    def effective_locale
      App::Constants::LOCALES.include?(locale.to_s) ? locale : I18n.default_locale
    end

    # --- 2FA TOTP (CYRA-170) ---

    # Il 2FA è attivo? È la sorgente di verità per il gate di login e per il gate god di Valhalla.
    def otp_enabled?
      otp_enabled_at.present?
    end

    # Genera e memorizza il seme TOTP se manca (idempotente): durante il setup riusa il seme provvisorio
    # già presente finché il 2FA non è confermato, così il QR resta stabile tra i refresh della pagina.
    def provision_otp_secret!
      update!(otp_secret: ROTP::Base32.random) if otp_secret.blank?
      otp_secret
    end

    # URI otpauth:// per il QR di provisioning (letto dall'app authenticator).
    def otp_provisioning_uri(label = email)
      ROTP::TOTP.new(otp_secret, issuer: Accounts::Constants::OTP_ISSUER).provisioning_uri(label)
    end

    # Verifica un codice TOTP con tolleranza di deriva dell'orologio (avanti/indietro). false su codice
    # vuoto o seme mancante. Anti-replay (CYRA-170 FIX-8): scarta i codici di un intervallo già consumato,
    # così lo STESSO codice non è riutilizzabile nella sua finestra (~90s). verify ritorna il timestamp
    # (Integer, inizio intervallo) del codice combaciante, oppure nil.
    # Consumo ATOMICO (FIX-E): l'UPDATE condizionato avanza otp_last_step_at solo se QUESTA richiesta
    # "vince" la finestra; due richieste concorrenti collo stesso codice → una sola tocca la riga, l'altra
    # vede 0 righe ed è rifiutata. Il WHERE è il vero gate anti-replay; il `after:` è solo un filtro rapido
    # (l'istanza può essere leggermente stale, mai più recente del DB → nessun falso rifiuto).
    def verify_otp(code)
      return false if otp_secret.blank? || code.blank?

      totp = ROTP::TOTP.new(otp_secret, issuer: Accounts::Constants::OTP_ISSUER)
      matched_at = totp.verify(code.to_s.strip, drift_behind: Accounts::Constants::OTP_DRIFT,
                                                drift_ahead: Accounts::Constants::OTP_DRIFT,
                                                after: otp_last_step_at)
      return false if matched_at.nil?

      step_time = Time.zone.at(matched_at)
      self.class.where(id: id)
          .where("otp_last_step_at IS NULL OR otp_last_step_at < ?", step_time)
          .update_all(otp_last_step_at: step_time)
          .positive?
    end

    # Attiva il 2FA (provisiona il seme se serve, marca otp_enabled_at) e RIGENERA i codici di recupero,
    # ritornati IN CHIARO una volta sola perché il controller li mostri. Atomico.
    def enable_otp!
      codes = nil
      transaction do
        provision_otp_secret!
        update!(otp_enabled_at: Time.current)
        codes = regenerate_recovery_codes!
      end
      codes
    end

    # Disattiva il 2FA: azzera seme + stato + anti-replay + tutti i codici di recupero. Atomico.
    # otp_last_step_at azzerato (FIX-8) così un re-enrollment immediato, entro la stessa finestra TOTP,
    # non si vede rifiutare il codice di conferma dal filtro anti-replay.
    def disable_otp!
      transaction do
        update!(otp_secret: nil, otp_enabled_at: nil, otp_last_step_at: nil)
        otp_recovery_codes.delete_all
      end
    end

    # Verifica e CONSUMA un codice di recupero (monouso): true se combaciava un codice non ancora usato.
    # Consumo ATOMICO (CYRA-170 FIX-7): l'UPDATE condizionato su `unused` marca used_at e ritorna il
    # numero di righe toccate in un solo statement → due richieste concorrenti non possono riusare lo
    # stesso codice (la seconda tocca 0 righe). find_by + update! non era atomico (race di doppio uso).
    def verify_recovery_code(code)
      digest = self.class.digest_recovery_code(code)
      return false if digest.blank?

      otp_recovery_codes.unused.where(code_digest: digest).update_all(used_at: Time.current).positive?
    end

    # Digest canonico di un codice di recupero: normalizza (strip/downcase/senza trattini) così l'input
    # dell'utente combacia col digest salvato a prescindere da formattazione/maiuscole.
    def self.digest_recovery_code(code)
      normalized = code.to_s.strip.downcase.delete("-")
      return nil if normalized.blank?

      Digest::SHA256.hexdigest(normalized)
    end

    private

    # Genera un handle unico dalla parte locale dell'email (o "user") quando non impostato. La
    # validazione uniqueness + l'indice unico restano la rete di sicurezza sulle race.
    def ensure_handle
      return if handle.present?

      base = email.to_s.split("@").first.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "")
      base = "user" if base.blank?
      candidate = base
      n = 0
      while Accounts::Account.where.not(id: id).exists?(handle: candidate)
        n += 1
        candidate = "#{base}#{n}"
      end
      self.handle = candidate
    end

    # Policy password (min 8 + 4 classi). Eseguita solo quando una password viene
    # impostata (create o cambio); i record caricati senza toccare la password sono esenti.
    def password_complexity
      return if password.blank?
      return if password.match?(Accounts::Constants::PASSWORD_FORMAT)

      errors.add(:password, :too_weak)
    end

    def god_reserved_for_humans
      errors.add(:god, :service_cannot_be_god) if god? && service?
    end

    # Sostituisce i codici di recupero con OTP_RECOVERY_CODES nuovi, ritornando i plaintext. Solo il
    # digest finisce in DB. Chiamato dentro la transazione di enable_otp!. Entropia (CYRA-170 FIX-6):
    # SecureRandom.hex(16) = 128 bit — hex(5) (40 bit) + SHA-256 veloce era brute-forzabile offline da
    # un dump del DB. 128 bit rendono il preimage infattibile.
    def regenerate_recovery_codes!
      otp_recovery_codes.delete_all
      Array.new(Accounts::Constants::OTP_RECOVERY_CODES).map do
        code = SecureRandom.hex(16)
        otp_recovery_codes.create!(code_digest: self.class.digest_recovery_code(code))
        code
      end
    end
  end
end
