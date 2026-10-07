# frozen_string_literal: true

module Secrets
  # Richiesta di approvazione a due (4-eyes) per un cambio di un secret in un ambiente protetto
  # (CYRA-138, Fase 4 pezzo C1a — FONDAMENTA). Congela l'INTENTO della modifica (impostare un valore o
  # cancellare il secret) finché un secondo responsabile non la decide. Qui c'è SOLO il modello e le sue
  # invarianti: l'intercettazione vera (chi la crea, da dove), la coda "in attesa" e l'applicazione
  # (approva/rifiuta/applica) arrivano nei pezzi successivi (C1b/C2) — vedi Secrets::Approval per il
  # guard che decide SE una coppia [progetto, ambiente] è protetta.
  class ChangeRequest < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :environment, class_name: "Types::Environment"
    belongs_to :organization, class_name: "Organizations::Organization"
    # requested_by/decided_by sono FK nullify (l'audit sopravvive alla cancellazione dell'account, come
    # Secrets::Event#actor): optional: true altrimenti Rails rifiuterebbe come invalido un record il cui
    # richiedente/decisore è stato nullificato dal DB dopo la creazione.
    belongs_to :requested_by, class_name: "Accounts::Account", optional: true
    belongs_to :decided_by, class_name: "Accounts::Account", optional: true
    # Versione sorgente opzionale: la richiesta può nascere da un ripristino puntuale (rollback).
    belongs_to :source_version, class_name: "Secrets::Version", optional: true

    # "delete" è un nome di metodo di classe PERICOLOSO per ActiveRecord::Enum: Model.delete(id) esiste
    # già su ActiveRecord::Base, quindi Rails rifiuta di generare uno scope `delete` (ArgumentError a
    # tempo di caricamento — verificato: ActiveRecord::Base.dangerous_class_method?(:delete) => true,
    # (:remove) => false). La chiave Ruby-side è perciò `remove`; il valore PERSISTITO nella colonna
    # resta la stringa "delete" (secondo elemento della coppia key: "value").
    enum :action, { set: "set", remove: "delete" }
    enum :status, { pending: "pending", applied: "applied", rejected: "rejected", cancelled: "cancelled" },
                  default: :pending

    # At-rest come Secrets::Variable/Secrets::Version: il valore proposto non transita MAI in chiaro
    # nella colonna/nei log (non-deterministico, non interrogabile per valore).
    encrypts :value

    # Identità/provenienza: immutabili dopo la creazione. Ciò che EVOLVE nei pezzi successivi è solo lo
    # stato della decisione (status/decided_by/decided_at/reason) — mai il "cosa/dove/chi ha chiesto".
    attr_readonly :project_id, :environment_id, :organization_id, :name, :action, :requested_by_id

    normalizes :name, with: ->(name) { name.to_s.strip.upcase }

    validates :name, presence: true, format: { with: Secrets::Variable::NAME_FORMAT }
    validates :action, presence: true
    # Prefisso riservato (GITHUB Actions lo rifiuta): stesso vincolo di Secrets::Variable, ma verificato
    # già QUI, alla creazione della richiesta — senza, una CR con nome GITHUB_x su un ambiente protetto
    # nascerebbe pending e fallirebbe solo in fase di applicazione (Secrets::ChangeRequests::Approve).
    validate :no_reserved_prefix
    # Tenant-integrity: environment e organization_id (denormalizzato) devono combaciare col progetto,
    # stesso pattern di Connections::ProjectEnvironment / Secrets::Variable.
    validate :environment_matches_project_organization
    validate :organization_matches_project
    validate :value_matches_action

    scope :for_project, ->(project) { where(project:) }
    scope :recent, -> { order(created_at: :desc) }

    # Allow a staged rollout before the additive migration is applied. CYRA-987
    def self.description_requests_supported?
      column_names.include?("description") && column_names.include?("description_only")
    end

    def proposed_description = has_attribute?(:description) ? self[:description] : nil

    def description_only_change? = has_attribute?(:description_only) && self[:description_only]
    # .pending è generato gratis dall'enum :status (scope named come la chiave "pending").

    private

    def no_reserved_prefix
      return if name.blank?

      errors.add(:name, :reserved_prefix) if name.start_with?(Secrets::Variable::RESERVED_NAME_PREFIX)
      errors.add(:name, :reserved_runtime) if Secrets::Variable.reserved_runtime_name?(name)
    end

    def environment_matches_project_organization
      return if project.blank? || environment.blank?

      errors.add(:environment, :invalid) if environment.organization_id != project.organization_id
    end

    def organization_matches_project
      return if project.blank?

      errors.add(:organization_id, :invalid) if organization_id != project.organization_id
    end

    # Il "cosa" della richiesta dev'essere coerente con l'azione: un set porta sempre il valore
    # proposto, una cancellazione non ne porta uno (niente da cifrare/mostrare per un delete).
    def value_matches_action
      return if action.blank?

      if description_only_change?
        errors.add(:description, :invalid) unless set? && !proposed_description.nil? && value.nil?
      elsif set? && value.nil?
        errors.add(:value, :blank)
      elsif remove? && value.present?
        errors.add(:value, :present)
      end
    end
  end
end
