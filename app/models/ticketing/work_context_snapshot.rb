# frozen_string_literal: true

module Ticketing
  # Fotografia IMMUTABILE della Guidance (references + procedures risolte) consegnata a un ticket alla
  # presa in carico (CYRA-76). Nasce nel flusso di claim dopo Guidance::Resolve e non cambia più: una
  # modifica successiva della guidance live NON altera lo snapshot storico (Scenario 2). Non c'è freeze
  # alla creazione del ticket — un claim tardivo cattura la guidance CORRENTE (Scenario 3).
  #
  # Immutabile via attr_readonly (come Ticketing::Report): correggere significa che non si corregge, è
  # una traccia storica. Una sola riga per ticket (indice unico su ticket_id): la creazione è idempotente
  # e claim concorrenti non duplicano. `payload_version` è la versione dello SCHEMA del payload, non un
  # contatore di versioni per ticket.
  class WorkContextSnapshot < ApplicationRecord
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :work_context_snapshot
    belongs_to :organization,
               class_name: "Organizations::Organization"
    # L'attore (service account dell'host) può sparire senza portarsi via lo snapshot: il nome resta
    # congelato in actor_name.
    belongs_to :actor,
               class_name: "Accounts::Account",
               optional: true

    attr_readonly :ticket_id, :organization_id, :actor_id, :actor_name,
                  :payload, :payload_version, :digest, :generated_at

    validates :payload_version, numericality: { only_integer: true, greater_than: 0 }
    validates :digest, presence: true
    validates :generated_at, presence: true
    # Integrità tenant: l'org denormalizzata deve combaciare con quella reale del ticket (via project).
    # Specchio di Ticketing::Event#organization_matches_ticket: lo scoping d'audit passa da
    # organization_id, una divergenza sarebbe un buco d'isolamento silenzioso.
    validate :organization_matches_ticket
    # L'attore, se presente, appartiene all'org del ticket (specchio di Ticketing::Report).
    validate :actor_belongs_to_organization

    # Digest CANONICO del contesto consegnato: SHA256 di { version, payload } con le chiavi di OGNI hash
    # ordinate ricorsivamente. Deve restare RICALCOLABILE dal payload persistito, ma jsonb non preserva
    # l'insertion order delle chiavi — senza canonicalizzazione il digest riletto dal DB non combacerebbe
    # mai con quello salvato e la firma sarebbe inverificabile (stesso motivo del FIELD_ORDER in
    # ActivityPresenter). Gli array (references/procedures) NON si riordinano: il loro ordine è
    # significativo e già deterministico (Guidance::Resolve ordina per position poi key).
    def self.compute_digest(payload, version: Ticketing::Constants::WORK_CONTEXT_PAYLOAD_VERSION)
      canonical = { "version" => version, "payload" => canonicalize(payload) }
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    def self.canonicalize(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, acc| acc[key] = canonicalize(value[key]) }
      when Array
        value.map { |element| canonicalize(element) }
      else
        value
      end
    end

    # Verifica d'integrità per l'audit: il digest salvato combacia con quello ricalcolato dal payload
    # persistito? Dimostra che lo snapshot ricostruisce esattamente le istruzioni fotografate.
    def digest_matches?
      digest == self.class.compute_digest(payload, version: payload_version)
    end

    private

    def organization_matches_ticket
      ticket_org_id = ticket&.project&.organization_id
      return if ticket_org_id.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != ticket_org_id
    end

    def actor_belongs_to_organization
      org_id = ticket&.project&.organization_id
      return if org_id.blank? || actor.blank?
      return if Connections::Membership.exists?(account_id: actor.id, organization_id: org_id)

      errors.add(:actor, :not_member)
    end
  end
end
