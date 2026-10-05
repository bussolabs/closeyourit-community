# frozen_string_literal: true

module Valhalla
  # Segnali operativi della dashboard god: stato organizzazioni (attive/sospese/senza owner),
  # accessi recenti (le sessioni sono il proxy dei login — una è creata a ogni login, vedi
  # Authentication#start_new_session_for), impersonation god recenti e crescita a 7 giorni di
  # account/organizzazioni/ticket. Query object dedicato per tenere thin il DashboardController
  # (pattern dei presenter esistenti, es. Projects::ToolsOverview).
  class DashboardSignals
    # Righe mostrate nelle tabelle "accessi recenti" e "impersonation recenti".
    RECENT_LIMIT = 8
    # Finestra della crescita recente.
    GROWTH_WINDOW = 7.days

    # `now` iniettabile per i test; @since fisso all'istanziazione così i tre conteggi di crescita
    # usano lo stesso confine temporale (nessuna deriva tra le query).
    def initialize(now: Time.current)
      @since = now - GROWTH_WINDOW
    end

    # One thing that needs the god: what it is, how bad, how many, and the page that fixes it.
    Attention = Data.define(:kind, :severity, :count, :target)

    def active_organizations_count
      Organizations::Organization.active.count
    end

    def suspended_organizations_count
      @suspended_organizations_count ||= Organizations::Organization.suspended.count
    end

    # Content hidden from search first (it breaks search for everyone), then the organizations.
    def attention
      drift = embedding_version_drift.drifted.map do |table|
        Attention.new(kind: :"drift_#{table.key}", severity: :danger, count: table.stale + table.missing, target: :ai_settings)
      end
      organizations = { suspended: suspended_organizations_count, without_owner: organizations_without_owner_count }
      drift + organizations.select { |_, count| count.positive? }
                           .map { |kind, count| Attention.new(kind: kind, severity: :warning, count: count, target: :organizations) }
    end

    # Organizzazioni senza owner (nessuna membership con role owner): vanno adottate, altrimenti
    # restano accessibili solo in god-mode. NOT IN (org con owner).
    def organizations_without_owner_count
      @organizations_without_owner_count ||= Organizations::Organization.where.not(id: owner_organization_ids).count
    end

    # Ultime SESSIONI ATTIVE per created_at: sono l'unico proxy dei login nel modello corrente. Le
    # sessioni sono distrutte al logout (Authentication#terminate_session) → qui compaiono solo quelle
    # ancora vive (scope active: né scadute né inattive), non uno storico dei login terminati. Preload
    # account/impersonated_account per l'email per riga (evita N+1 → prosopite).
    def recent_sessions
      Accounts::Session.active
        .includes(:account, :impersonated_account)
        .order(created_at: :desc)
        .limit(RECENT_LIMIT)
    end

    # Ultimi eventi di impersonation god → account (audit storico). Preload god/account per l'email.
    def recent_impersonation_events
      Accounts::ImpersonationEvent
        .includes(:god, :account)
        .order(started_at: :desc)
        .limit(RECENT_LIMIT)
    end

    # Coppie [god_id, target_id] delle impersonation REALMENTE in corso ora = fonte di verità = sessioni
    # vive con impersonated_account_id. Un evento con ended_at nullo NON basta a dire "in corso": il
    # logout distrugge la sessione ma non chiude l'evento. La view marca "in corso" solo le righe la
    # cui coppia è in questo set.
    def active_impersonation_pairs
      Accounts::Session.active
        .where.not(impersonated_account_id: nil)
        .pluck(:account_id, :impersonated_account_id)
        .to_set
    end

    # Drift di versione degli embedding: righe embeddate ma non correnti = INVISIBILI alla ricerca
    # semantica (lo scope current_embedding le filtra). Segnale operativo di sistema (cross-tenant,
    # non per-org): se positivo, ricerca/duplicati/RAG vedono solo una frazione dei dati. Rimedio:
    # Embeddings::BackfillVersionJob. Vedi CYRA-206.
    def embedding_version_drift
      @embedding_version_drift ||= Embeddings::VersionDrift.call
    end

    def accounts_last_7_days
      Accounts::Account.where(created_at: @since..).count
    end

    def organizations_last_7_days
      Organizations::Organization.where(created_at: @since..).count
    end

    def tickets_last_7_days
      Ticketing::Ticket.where(created_at: @since..).count
    end

    private

    def owner_organization_ids
      Connections::Membership.where(role: :owner).select(:organization_id)
    end
  end
end
