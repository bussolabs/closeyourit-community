# frozen_string_literal: true

module Connections
  # Imposta il confine ambienti sui secret di un account: allow-list org-wide sulla membership +
  # override per singolo progetto (CYRA-78). Un solo punto di scrittura per i due livelli, così
  # l'editing umano (Member::MembersController#update_access) e quello dei service account non possono
  # divergere sulle regole.
  #
  # Anti-lockout: i code sono SEMPRE intersecati con quelli realmente dichiarati dall'organizzazione
  # (stesso pattern di Member::Service::AccountsController#update). Un refuso salverebbe altrimenti una
  # allow-list che non corrisponde a nessun ambiente — cioè un divieto totale, silenzioso.
  # Anti-BOLA: i progetti arrivano dai parametri, quindi si accettano solo quelli dell'org della
  # membership; gli altri sono ignorati, mai un errore che riveli se esistono.
  # Transazionale: allow-list e override si salvano insieme o per niente (un salvataggio rifiutato a
  # metà lascerebbe un confine che nessuno ha scelto).
  class SetSecretAccess < ApplicationService
    def initialize(membership:, org_wide_codes:, per_project: {})
      @membership = membership
      @org_wide_codes = org_wide_codes
      @per_project = per_project || {}
    end

    def call
      ActiveRecord::Base.transaction do
        @membership.update!(secret_environment_codes: sanitize(@org_wide_codes))
        @per_project.each { |project_id, codes| apply_override(project_id, codes) }
      end
      Result.ok(@membership)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-SECRET-002", details: e.record&.errors&.to_hash))
    end

    private

    def organization = @membership.organization

    def organization_codes
      @organization_codes ||= organization.environments.pluck(:code)
    end

    def sanitize(codes)
      Array(codes).map { |code| code.to_s.strip.downcase }.reject(&:blank?).uniq & organization_codes
    end

    # Lista vuota = nessun override: la riga si cancella invece di restare vuota (una allow-list vuota
    # significherebbe "eredita l'org-wide" anche stando lì, ma sporcherebbe la lettura).
    def apply_override(project_id, codes)
      project = organization.projects.find_by(id: project_id)
      return if project.nil?

      sanitized = sanitize(codes)
      record = AccountSecretAccess.find_or_initialize_by(account_id: @membership.account_id, project_id: project.id)
      return record.destroy! if sanitized.empty? && record.persisted?
      return if sanitized.empty?

      # organization_id è attr_readonly: si valorizza solo alla nascita della riga (sulle esistenti è
      # già quello del progetto, garantito dal tenant guard del model).
      record.organization_id = project.organization_id if record.new_record?
      record.environment_codes = sanitized
      record.save!
    end
  end
end
