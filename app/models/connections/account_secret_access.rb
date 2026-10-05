# frozen_string_literal: true

module Connections
  # Override PER-PROGETTO della restrizione ambienti sui secret (CYRA-78). Una riga dice: «su QUESTO
  # progetto, questo account può toccare i secret solo di questi environment», e vince sulla allow-list
  # org-wide (Connections::Membership#secret_environment_codes). Nessuna riga = si eredita l'org-wide;
  # nessuna delle due = nessuna restrizione. La precedenza vive in Secrets::EnvironmentAccess.
  #
  # Una riga con `environment_codes` VUOTO non è un "vieta tutto": significa nessun override, quindi si
  # torna a ereditare l'org-wide. Connections::SetSecretAccess la cancella invece di salvarla vuota —
  # il fail-closed sarebbe un lockout silenzioso di chi non ha mai chiesto una restrizione per-progetto.
  class AccountSecretAccess < ApplicationRecord
    belongs_to :account, class_name: "Accounts::Account"
    belongs_to :project, class_name: "Projects::Project", inverse_of: :account_secret_accesses
    belongs_to :organization, class_name: "Organizations::Organization"

    # Il legame [account, progetto, org] è l'identità della riga: si cambia solo la allow-list.
    attr_readonly :account_id, :project_id, :organization_id

    # Stessa normalizzazione della allow-list org-wide (Connections::Membership): code puliti,
    # minuscoli, senza vuoti né doppioni — così il confronto con Types::Environment#code non fallisce
    # per uno spazio o una maiuscola.
    normalizes :environment_codes,
               with: ->(codes) { Array(codes).map { |c| c.to_s.strip.downcase }.reject(&:blank?).uniq }

    validates :account_id, uniqueness: { scope: :project_id }
    validate :project_matches_organization

    private

    # Tenant guard: l'org denormalizzata deve essere quella del progetto, altrimenti la riga sarebbe
    # invisibile agli scope d'organizzazione pur restando attiva sul progetto.
    def project_matches_organization
      return if project.blank? || organization_id.blank?

      errors.add(:organization, :invalid) if project.organization_id != organization_id
    end
  end
end
