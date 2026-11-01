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
  # Anti-allargamento (CYRA-1118): una lista INVIATA piena che la pulizia svuota è rifiutata
  # (R422-SECRET-008) — vuota varrebbe "tutti gli ambienti", per chiunque la mandi. E con `actor:` non
  # unscoped, Authorization::SecretEnvironmentGuard rifiuta (R403-ACCESS-001) un confine che apre
  # ambienti che l'attore non vede, o toglie il limite a chi l'aveva, su ogni progetto in cui il confine
  # effettivo cambia. Entrambi girano PRIMA di scrivere.
  # Anti-BOLA: i progetti arrivano dai parametri, quindi si accettano solo quelli dell'org della
  # membership; gli altri sono ignorati, mai un errore che riveli se esistono.
  # Transazionale: allow-list e override si salvano insieme o per niente (un salvataggio rifiutato a
  # metà lascerebbe un confine che nessuno ha scelto). La verifica gira nella stessa transazione, sotto
  # lock delle membership coinvolte (#lock_boundaries!): richieste concorrenti non possono comporre un
  # confine che nessuna delle due ha verificato.
  class SetSecretAccess < ApplicationService
    # Una lista inviata con almeno un nome che, ripulita ai soli ambienti reali, resta vuota. Condiviso
    # con Accounts::Service::Create, che fa la stessa pulizia alla nascita dell'account.
    def self.unknown_only?(submitted, sanitized)
      sanitized.empty? && Array(submitted).any? { |code| code.to_s.strip.present? }
    end

    # Lock condiviso del confine ambienti: FOR UPDATE sulle membership degli account indicati (target e
    # attore) nell'org, in ordine di id contro i deadlock. Chi legge, verifica e scrive un confine — qui
    # e alla nascita di un service account (Accounts::Service::Create) — lo prende prima di leggere,
    # dentro la transazione che scrive: richieste concorrenti non possono comporre un confine che
    # nessuna delle due ha verificato.
    def self.lock_boundaries!(organization_id:, account_ids:)
      Membership.where(organization_id: organization_id, account_id: account_ids.compact.uniq)
                .order(:id).lock.pluck(:id)
    end

    def self.unknown_only_error
      AppError.new("Nessuno degli ambienti indicati esiste: una lista vuota darebbe accesso a tutti gli ambienti",
                   code: "R422-SECRET-008")
    end

    def initialize(membership:, org_wide_codes:, per_project: {}, actor: nil)
      @membership = membership
      @org_wide_codes = org_wide_codes
      @per_project = per_project || {}
      @actor = actor
    end

    def call
      result = nil
      ActiveRecord::Base.transaction do
        lock_boundaries!
        org_wide = sanitize(@org_wide_codes)
        overrides = requested_overrides
        barrier = unknown_only_barrier(org_wide, overrides) || escalation_barrier(org_wide, overrides)
        if barrier
          result = Result.err(barrier)
          raise ActiveRecord::Rollback
        end

        @membership.update!(secret_environment_codes: org_wide)
        overrides.each { |project, codes, _submitted| apply_override(project, codes) }
        result = Result.ok(@membership)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-SECRET-002", details: e.record&.errors&.to_hash))
    end

    private

    def organization = @membership.organization

    # Lettura, verifica e scrittura del confine sono serializzate: senza lock due richieste che leggono
    # lo stesso confine passano entrambe il guard e l'ultima scrittura ne compone uno che nessuna delle
    # due ha verificato (es. org-wide riportata a illimitata dopo che l'altra ha cancellato l'override
    # che limitava un progetto). Si bloccano la membership del target e quella dell'attore (il suo
    # confine è l'altro termine del confronto); poi si rilegge il target, perché il confine "prima" sia
    # quello committato dall'ultima richiesta.
    def lock_boundaries!
      self.class.lock_boundaries!(organization_id: @membership.organization_id,
                                  account_ids: [ @membership.account_id, @actor&.id ])
      @membership.reload
    end

    def organization_codes
      @organization_codes ||= organization.environments.pluck(:code)
    end

    def sanitize(codes)
      Array(codes).map { |code| code.to_s.strip.downcase }.reject(&:blank?).uniq & organization_codes
    end

    # [[progetto, code sanificati, code inviati]] per i soli progetti dell'org (anti-BOLA).
    def requested_overrides
      @per_project.filter_map do |project_id, codes|
        project = organization.projects.find_by(id: project_id)
        [ project, sanitize(codes), codes ] if project
      end
    end

    def unknown_only_barrier(org_wide, overrides)
      unknown = self.class.unknown_only?(@org_wide_codes, org_wide) ||
                overrides.any? { |_project, sanitized, submitted| self.class.unknown_only?(submitted, sanitized) }
      self.class.unknown_only_error if unknown
    end

    # Il confine prima e dopo, interi: anche i progetti che la richiesta non nomina cambiano quando
    # cambia la org-wide e il target non ha override lì (il guard li controlla tutti).
    def escalation_barrier(org_wide, overrides)
      current = Authorization::SecretEnvironmentGuard::Boundary.new(
        org_wide: @membership.secret_environment_codes || [],
        overrides: AccountSecretAccess.where(account_id: @membership.account_id, organization_id: organization.id)
                                      .pluck(:project_id, :environment_codes).to_h
      )
      requested = current.with(
        org_wide: org_wide,
        overrides: current.overrides.merge(overrides.to_h { |project, sanitized, _submitted| [ project.id, sanitized ] })
      )
      Authorization::SecretEnvironmentGuard.barrier(actor: @actor, organization: organization,
                                                    requested: requested, current: current)
    end

    # Lista vuota = nessun override: la riga si cancella invece di restare vuota (una allow-list vuota
    # significherebbe "eredita l'org-wide" anche stando lì, ma sporcherebbe la lettura).
    def apply_override(project, sanitized)
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
