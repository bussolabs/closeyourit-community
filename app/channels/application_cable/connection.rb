# frozen_string_literal: true

module ApplicationCable
  # Connessione ActionCable autenticata. Riusa la stessa sessione cookie dell'area web:
  # cookie firmato `session_id` -> Accounts::Session (identica a Authentication#find_session_by_cookie),
  # e l'account "visto" = impersonated_account || account (come resume_session).
  #
  # Tenant: l'organizzazione corrente è risolta come nell'area member (OrganizationContext) —
  # `session[:organization_id]` validata contro le membership dell'account (anti-BOLA), con
  # fallback alla prima membership. Senza sessione valida -> reject. Se la sessione richiede
  # esplicitamente un'org su cui l'account NON ha membership -> reject (BOLA).
  #
  # NB: l'isolamento reale degli stream è garantito dai nomi-stream firmati e tenant-prefissati
  # di Realtime::Streams; questi identificatori servono per identità/diagnostica e come difesa
  # in profondità (nessuna connessione anonima).
  class Connection < ActionCable::Connection::Base
    identified_by :current_account, :current_organization, :current_session

    def connect
      self.current_session = find_verified_session
      self.current_account = current_session.impersonated_account || current_session.account
      self.current_organization = resolve_current_organization
      reject_suspended_organization
      tag_logger
    end

    # Reload identity on delivery: an already-open socket must not outlive revocation.
    def live_account
      live_session = Accounts::Session.active.includes(:account, :impersonated_account).find_by(id: current_session.id)
      return unless live_session

      account = live_session.impersonated_account || live_session.account
      return unless account.id == current_account.id
      return account unless current_organization

      organization = Organizations::Organization.find_by(id: current_organization.id)
      return unless organization && (!organization.suspended? || live_session.account.god?)
      return unless Connections::Membership.exists?(account_id: account.id, organization_id: organization.id)

      account
    end

    private

    # CYRA-722 — chiusa la porta HTTP dell'area utenti resta questa: una pagina già caricata tiene il
    # suo canale in tempo reale e continua a ricevere messaggi, presenze e aggiornamenti
    # dell'organizzazione sospesa. È lo stesso accesso, per un'altra via, e non lo si vede nei log
    # delle richieste perché di richieste non ne fa più nessuna.
    #
    # Il god passa, come nell'area web: è lui a sospendere. Qui l'account "vero" è
    # current_session.account (current_account può essere quello impersonato), lo stesso criterio di
    # Current.true_account lato HTTP.
    def reject_suspended_organization
      return unless current_organization&.suspended?
      return if current_session.account.god?

      reject_unauthorized_connection
    end

    # Stessa logica di Authentication#find_session_by_cookie: solo sessioni ANCORA VALIDE (scope
    # :active = non scadute e non idle). Le righe sessione si distruggono solo pigramente su richiesta
    # HTTP, quindi senza .active un cookie oltre SESSION_ABSOLUTE_TTL/IDLE_TIMEOUT continuerebbe ad
    # aprire WebSocket (CYRA-272). Cookie assente o sessione non valida -> reject (halt).
    def find_verified_session
      session_id = cookies.signed[:session_id]
      reject_unauthorized_connection if session_id.blank?

      Accounts::Session.active.find_by(id: session_id) || reject_unauthorized_connection
    end

    # Org corrente come l'area member: org richiesta in sessione (se presente) validata contro
    # le membership dell'account, altrimenti prima membership. Nessuna org legittima -> nil:
    # la connessione resta valida per gli stream account-scoped (es. notifiche personali).
    def resolve_current_organization
      memberships = current_account.memberships.includes(:organization)
      wanted_id = wanted_organization_id

      if wanted_id.present?
        membership = memberships.find { |m| m.organization_id == wanted_id }
        reject_unauthorized_connection unless membership # BOLA: org non posseduta dall'account
        membership.organization
      else
        memberships.first&.organization
      end
    end

    # session[:organization_id] vive nel cookie di sessione cifrato (CookieStore di default).
    # Best-effort: qualunque errore di lettura -> nil (fallback alla prima membership), mai raise.
    # Un fallimento di lettura NON può aggirare la BOLA: l'org risolta è sempre una membership
    # reale dell'account.
    def wanted_organization_id
      session_hash = cookies.encrypted[session_cookie_key]
      return if session_hash.blank?

      (session_hash["organization_id"] || session_hash[:organization_id]).presence
    rescue StandardError
      nil
    end

    def session_cookie_key
      Rails.application.config.session_options[:key]
    end

    def tag_logger
      logger.add_tags(*[ "ActionCable", "Account #{current_account.id}",
                         current_organization && "Org #{current_organization.id}" ].compact)
    end
  end
end
