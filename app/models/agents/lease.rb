# frozen_string_literal: true

module Agents
  # Mutua esclusione server-side di una lavorazione su un ticket. La riga è riutilizzata
  # dopo la scadenza; l'indice DB su ticket_id è l'autorità sotto acquire concorrenti.
  #
  # CYRA-293 — il titolare è polimorfo: un host automator OPPURE un account (persona o service account
  # che lavora dalla CLI). Una tabella separata per gli umani non darebbe mutua esclusione: due tabelle
  # non si escludono a vicenda, e un umano potrebbe prendere un ticket già tenuto da un host.
  class Lease < ApplicationRecord
    attr_readonly :organization_id, :ticket_id

    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :agent_leases
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :agent_lease
    belongs_to :host,
               class_name: "Agents::Host",
               inverse_of: :leases,
               optional: true
    belongs_to :account,
               class_name: "Accounts::Account",
               optional: true

    validates :run_id, :expires_at, presence: true
    validates :run_id, :agent, length: { maximum: 255 }
    # Host-first (CYAU-96): la fase eseguibile e l'impronta del profilo (PhaseProfile#digest) sostituiscono
    # lo slug `agent`. Nullable in dual-stack (i lease legacy prompt-mode hanno agent, questi NULL); se
    # presenti, execution_phase deve essere una fase nota e profile_digest un SHA256 esadecimale a 64 char.
    validates :execution_phase, inclusion: { in: Agents::PhaseProfile::PHASES }, allow_nil: true
    validates :profile_digest, length: { is: 64 }, allow_nil: true
    validates :authoritative_ttl_seconds,
              numericality: { only_integer: true, in: 1..30.days.to_i },
              allow_nil: true
    validate :associations_belong_to_organization
    validate :exactly_one_holder
    validate :dual_stack_identity

    def active_at?(time) = expires_at > time

    # Titolare account: presa in carico dichiarata da una persona o da un service account via CLI.
    # Non ha identità di lavoro agente (nessuna fase da eseguire, nessuno slug da consegnare).
    def human? = account_id.present?

    def held_by?(holder) = holder.present? && holder.kind == holder_kind && holder.id == holder_id

    def holder_kind = human? ? :account : :host

    def holder_id = human? ? account_id : host_id

    private

    def associations_belong_to_organization
      return if organization_id.blank?

      errors.add(:host, :invalid) if host&.organization_id.present? && host.organization_id != organization_id
      errors.add(:account, :invalid) if account_id.present? && !account_in_organization?
      return unless ticket&.project&.organization_id.present?

      errors.add(:ticket, :invalid) if ticket.project.organization_id != organization_id
    end

    # Il titolare account deve essere membro dell'organizzazione del lease: senza questo, un account di
    # un'altra org potrebbe occupare un ticket che non vede. L'host ha il confronto diretto su
    # organization_id, l'account passa dalle membership e costa una query — accettabile perché la
    # scrittura di un lease è rara e l'alternativa (fidarsi del solo controllo nel service) lascerebbe
    # l'invariante fuori dal modello.
    def account_in_organization?
      Connections::Membership.exists?(organization_id:, account_id:)
    end

    # Un lease ha esattamente un titolare: host automator O account. Gemello del check_constraint
    # agents_leases_holder. Senza titolare il ticket resterebbe occupato fino alla scadenza senza che
    # nessuno possa rilasciarlo; con due titolari ogni verifica di possesso sarebbe ambigua.
    def exactly_one_holder
      return if host_id.present? ^ account_id.present?

      errors.add(:base, :invalid_holder)
    end

    # Dual-stack: un lease host deve avere un'identità di lavoro consegnabile — o lo slug agent legacy, o
    # la coppia COMPLETA fase+impronta host-first. Vietati i record malformati (vuoti, o host-first parziali
    # con fase senza impronta o viceversa) che bloccherebbero la coda fino alla scadenza senza mai superare
    # la rivalidazione della delivery. Gemello del check_constraint agents_leases_work_identity.
    #
    # Terzo ramo (CYRA-293): il lease di un account non consegna lavoro agente — nessuna fase da eseguire,
    # nessuno slug da attribuire — quindi le pretende tutte assenti. Un lease umano che portasse una fase
    # pinnata entrerebbe nei rami di delivery host senza un host che possa eseguirli.
    def dual_stack_identity
      return if human? && execution_phase.blank? && profile_digest.blank? && agent.blank?

      host_first = execution_phase.present? && profile_digest.present?
      legacy = execution_phase.blank? && profile_digest.blank? && agent.present?
      return if !human? && (host_first || legacy)

      errors.add(:base, :invalid_work_identity)
    end
  end
end
