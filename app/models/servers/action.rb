# frozen_string_literal: true

module Servers
  class Action < ApplicationRecord
    # apply_security_updates tocca solo le origini di sicurezza (unattended-upgrade), apply_all_updates
    # aggiorna tutti i pacchetti installati (apt-get upgrade): su un host con soli aggiornamenti
    # ordinari in attesa, il primo esce con 0 senza installare niente ed è il secondo che serve.
    KINDS = %w[apply_security_updates apply_all_updates reboot].freeze
    # apply_all_updates esiste solo dagli agent 0.8.0 in su: sotto, l'executor rifiuta l'azione con
    # "tipo azione non supportato". La UI non la offre agli host più vecchi (vedi Host#supports?).
    KIND_MIN_AGENT_VERSION = { "apply_all_updates" => Gem::Version.new("0.8.0") }.freeze
    OUTPUT_MAX = 20_000

    belongs_to :host, class_name: "Servers::Host", inverse_of: :actions
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :requested_by, class_name: "Accounts::Account", optional: true

    # `interrupted` (CYRA-809) è l'esito che mancava: l'azione È partita e l'esito non si sa. NON è
    # `expired` — quella non è mai partita — e non è `failed`, che affermerebbe una cosa che nessuno
    # ha visto. È l'unico esito RECUPERABILE: se il server ritorna e racconta com'è andata,
    # Actions::Complete la porta a succeeded/failed (l'esito tardivo). Sta fuori da `active`, quindi
    # libera l'unico posto attivo per host — il blocco che teneva ferme tutte le azioni successive.
    enum :status, { queued: 0, running: 1, succeeded: 2, failed: 3, cancelled: 4, expired: 5,
                    interrupted: 6 }, prefix: true

    validates :kind, inclusion: { in: KINDS }
    validates :idempotency_key, :expires_at, presence: true
    validates :idempotency_key, uniqueness: { scope: :host_id }
    validate :same_organization

    scope :active, -> { where(status: %i[queued running]) }
    # Le azioni partite e mai concluse: autorizzazione scaduta E lease silenziosa da oltre la grazia.
    # Il confronto cade su started_at (e in ultima istanza su created_at) perché una running senza
    # lease — una riga incoerente, o scritta prima che la lease esistesse — sarebbe altrimenti
    # invisibile a questo scope e resterebbe bloccata per sempre, che è il bug di partenza.
    scope :orphaned, lambda { |now = Time.current, after: Servers::Constants::ACTION_ORPHAN_AFTER_SECONDS|
      status_running.where(expires_at: ..now)
                    .where("COALESCE(servers_actions.lease_expires_at, servers_actions.started_at, " \
                           "servers_actions.created_at) <= ?", now - after.seconds)
    }

    def expired?(now = Time.current) = expires_at <= now

    private

    def same_organization
      errors.add(:organization, :invalid) if host && organization_id != host.organization_id
    end
  end
end
