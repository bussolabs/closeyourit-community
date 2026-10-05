# frozen_string_literal: true

module Agents
  class Attempt < ApplicationRecord
    TERMINAL_STATUSES = %w[approved rejected failed review_failed stale cancelled].freeze

    # Execution profile immutabile: descrive COME è stato eseguito il tentativo (host-first) ed è
    # leggibile senza Agent/Command/Instruction. Congelato dopo la creazione — host/fase/runtime +
    # skill/sandbox/permessi/tool/ttl/bundle/service_account. Con raise_on_assign_to_attr_readonly ogni
    # tentativo di modifica solleva ActiveRecord::ReadonlyAttributeError.
    attr_readonly :host_id, :phase, :runtime, :skill_key, :sandbox, :permission_mode,
                  :allowed_tools, :ttl, :bundle_digest, :bundle_ref, :service_account_id

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :workflow, class_name: "Agents::Workflow", inverse_of: :attempts
    belongs_to :host, class_name: "Agents::Host"
    # Host-first: il service account dell'host che ha eseguito la fase. Le FK legacy verso agente, comando,
    # istruzione e run sono cadute con la rimozione dei typed agent (MT-9); le colonne restano nullable e
    # valorizzate a NULL sui record storici, che così sopravvivono senza il puntatore.
    belongs_to :service_account, class_name: "Accounts::Account", optional: true

    enum :status, { running: 0, awaiting_review: 1, approved: 2, rejected: 3, failed: 4,
                    review_failed: 5, stale: 6, cancelled: 7 }, prefix: true
    enum :review_status, { pending: 0, accepted: 1, changes_requested: 2, unavailable: 3 },
                         prefix: true, allow_nil: true

    validates :phase, :runtime, :idempotency_key, :external_run_id, :started_at, presence: true
    validates :idempotency_key, uniqueness: { scope: :organization_id }
    validate :tenant_integrity
    validate :execution_identity_present

    # Lavorazioni ORFANE (CYRA-201): prenotazione scaduta e nessuna consegna registrata. Nessuno le chiude,
    # quindi restavano `running` per sempre — occupando le viste degli attempt attivi e, peggio, facendosi
    # scambiare da TicketQueues::Claim#idempotent_replay? per un tentativo già in corso, che blocca i claim
    # successivi sullo stesso ticket.
    #
    # Il confronto è sul `run_id`, NON sul solo ticket: il ticket è unico ma le lavorazioni no. Un lease
    # FRESCO appartenente a un'ALTRA lavorazione dello stesso ticket non tiene in vita questa (è la stessa
    # distinzione che fa `auditRecovery` lato automator: host + run, non il ticket).
    #
    # `delivery_digest` nil è il segno che la richiesta non è mai arrivata: una consegna rifiutata in
    # validazione avrebbe lasciato `review_failed` + `finished_at`, quindi non è più `running`.
    scope :orphaned_at, lambda { |time, grace: Agents::Constants::ATTEMPT_STALE_GRACE|
      status_running
        .where(delivery_digest: nil)
        .where(started_at: ..(time - grace))
        .left_joins(workflow: { ticket: :agent_lease })
        .where(
          "agents_leases.id IS NULL OR agents_leases.expires_at <= :deadline " \
          "OR agents_leases.run_id <> agents_attempts.external_run_id",
          deadline: time - grace
        )
    }

    before_update :ensure_mutable

    private

    def ensure_mutable
      raise ActiveRecord::ReadOnlyRecord, "Il tentativo terminale è audit immutabile" if status_was.in?(TERMINAL_STATUSES)
    end

    # Un attempt DEVE avere l'identità di esecuzione host-first completa: il service account dell'host che
    # ha eseguito, più la skill della fase. Il ramo legacy (agente+comando+istruzione) è caduto con i typed
    # agent (MT-9); i record storici conservano le colonne a NULL e restano leggibili, ma non se ne creano
    # più. Un profilo parziale resta un record malformato, non un caso ammesso.
    def execution_identity_present
      return if service_account_id.present? && skill_key.present?

      errors.add(:base, :incomplete_host_first_identity)
    end

    def tenant_integrity
      ids = [ workflow&.organization&.id, host&.organization_id ].compact
      errors.add(:organization, :invalid) unless ids.all? { |id| id == organization_id }
      return if service_account.blank?

      # Il service account host-first deve essere un account di SERVIZIO membro dell'org (gemello del
      # vincolo su Agents::Host: l'identità operativa non è mai un account umano).
      return if service_account.service? && service_account.memberships.exists?(organization_id: organization_id)

      errors.add(:service_account, :invalid)
    end
  end
end
