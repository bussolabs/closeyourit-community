module Connections
  class Membership < ApplicationRecord
    belongs_to :account,
               class_name: "Accounts::Account",
               inverse_of: :memberships
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :memberships

    # customer: ruolo "esterno" che può vedere e aprire ticket, ma non gestire (no edit/assign/manage).
    enum :role, { member: 0, admin: 1, owner: 2, customer: 3 }, default: :member

    # Restrizione OPZIONALE degli environment (Types::Environment#code) su cui questo account può
    # accedere ai secret via CLI: vuoto = nessuna restrizione (tutti gli env dei progetti visibili).
    # Usata dai service account per confinare l'accesso (es. "niente production"). Gli umani la lasciano
    # vuota (usano l'RBAC). Enforce in Cli::V1::Projects::SecretsController.
    normalizes :secret_environment_codes,
               with: ->(codes) { Array(codes).map { |c| c.to_s.strip.downcase }.reject(&:blank?).uniq }

    validates :account_id, uniqueness: { scope: :organization_id }
    validates :role, presence: true
    validate :single_owner_per_organization, if: :owner?

    # Vero se l'account sta DENTRO il gruppo di lavoro dell'organizzazione: qualsiasi ruolo tranne
    # `customer`, che è l'unico esterno. Il god passa sempre, anche senza membership (cross-tenant
    # nativo, come Authorization::VisibleScope.unscoped?).
    #
    # CYRA-848 — vive qui perché il ruolo vive qui, e i posti che devono distinguere «interno» da
    # «cliente» sono più d'uno (le domande riservate su un ticket, per cominciare).
    #
    # Fail-closed: senza account, senza organizzazione o senza membership non c'è nessuno da
    # riconoscere come interno → esterno.
    def self.internal_actor?(account:, organization:)
      return false if account.nil? || organization.nil?
      return true if account.god?

      where(account_id: account.id, organization_id: organization.id).where.not(role: :customer).exists?
    end

    # Vero se l'account può toccare i secret dell'environment `code`: nessuna restrizione (lista vuota)
    # → sempre; altrimenti solo i code elencati.
    def secret_environment_allowed?(code)
      codes = secret_environment_codes
      codes.blank? || codes.include?(code.to_s)
    end

    private

    def single_owner_per_organization
      return if organization_id.blank?

      conflict = self.class
                     .where(organization_id: organization_id, role: :owner)
                     .where.not(id: id)
      errors.add(:role, :taken) if conflict.exists?
    end
  end
end
