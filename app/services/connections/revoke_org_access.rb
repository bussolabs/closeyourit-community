# frozen_string_literal: true

module Connections
  # Revoca in un colpo solo TUTTO l'accesso di un account a un'organizzazione — chiavi CLI, scope
  # per-progetto/gruppo, ruoli diretti, override personali, appartenenza ai team, preferenze di notifica,
  # sottoscrizioni ai ticket e avvisi in sospeso — e infine rimuove la membership. Transazionale: o tutto
  # o niente (rollback su errore), così non resta mai un accesso orfano né revocato a metà. Sorgente UNICA
  # condivisa da Accounts::Service::Retire (service account) e Connections::RemoveMember (membro umano).
  # Result pattern.
  #
  # Ordine OBBLIGATO: le chiavi si revocano MENTRE la membership esiste ancora — Accounts::ApiTokens::Revoke
  # fa un update! che rivalida account_is_member_of_organization; a membership già rimossa fallirebbe. Poi
  # si azzera l'accesso scoped e, per ULTIMA, si rimuove la membership.
  #
  # Le notifiche dei ticket si spengono ALLA FONTE: rimosse le Ticketing::Subscription, i dispatcher
  # (DispatchEvent/DispatchComment, che iterano ticket.subscribers) non hanno più destinatari orfani; le
  # notifiche email già trattenute (held/queued in attesa di digest) si annullano a :skipped, così
  # ReleaseHeldJob/DigestJob non le consegnano a chi non è più membro.
  #
  # NON tocca Accounts::Session (è per-account, non per-org): una sessione web non concede accesso ai dati
  # di un'org da cui sei stato rimosso — l'autorizzazione è LIVE via Authorization::Resolver.
  #
  # invalid_code: codice AppError del fallback RecordInvalid — i chiamanti che espongono un contratto
  # d'errore proprio lo sovrascrivono (Retire → R422-SERVICEACCOUNT-002).
  class RevokeOrgAccess < ApplicationService
    def initialize(account:, organization:, invalid_code: "R422-MEMBER-005")
      @account = account
      @organization = organization
      @invalid_code = invalid_code
    end

    def call
      failure = nil

      ActiveRecord::Base.transaction do
        revoke_api_tokens

        failing = access_reset_steps.find(&:err?)
        if failing
          # Uno step di accesso è fallito: rollback completo (chiavi/accesso ripristinati) e la membership
          # NON viene rimossa → nessun accesso orfano o revocato a metà.
          failure = failing.error
          raise ActiveRecord::Rollback
        end

        remove_team_memberships
        remove_invitations
        remove_ticket_subscriptions
        remove_alerting_preferences
        cancel_pending_notifications
        remove_membership
      end

      return Result.err(failure) if failure

      Result.ok(@account)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: @invalid_code, details: e.record&.errors&.to_hash))
    end

    private

    def revoke_api_tokens
      @account.api_tokens.where(organization: @organization, revoked_at: nil).each do |token|
        Accounts::ApiTokens::Revoke.call(token: token)
      end
    end

    def access_reset_steps
      [
        Connections::SetMemberAccess.call(organization: @organization, account: @account,
                                          group_ids: [], project_ids: []),
        Authorization::SetAccountRoles.call(organization: @organization, account: @account, role_ids: []),
        Authorization::SetAccountPermissions.call(organization: @organization, account: @account,
                                                  allow_keys: [], deny_keys: [])
      ]
    end

    def remove_team_memberships
      Connections::TeamMembership
        .where(account_id: @account.id, team_id: @organization.teams.select(:id))
        .destroy_all
    end

    # Inviti di quella email a QUESTA org: una persona rimossa non deve lasciarsi dietro la riga che
    # la riporterebbe dentro (invito pendente) né quella che impedirebbe di reinvitarla, che finché
    # l'indice era pieno era il vero blocco. Scoped all'org: la stessa email invitata altrove resta.
    def remove_invitations
      Connections::Invitation
        .where(organization_id: @organization.id, email: @account.email)
        .delete_all
    end

    # Watcher dei ticket dell'org: spegne alla fonte i dispatcher delle notifiche ticket (iterano
    # ticket.subscribers) → un ex-membro non riceve più aggiornamenti dei ticket che seguiva.
    def remove_ticket_subscriptions
      Ticketing::Subscription.where(account_id: @account.id, organization_id: @organization.id).delete_all
    end

    def remove_alerting_preferences
      Alerting::Preference.where(account_id: @account.id, organization_id: @organization.id).destroy_all
    end

    # Avvisi email già trattenuti in attesa del digest (held per quiet hours, queued per cadenza): annulla
    # a :skipped così ReleaseHeldJob/DigestJob non li consegnano a chi non è più membro. Le in-app non si
    # toccano: senza accesso all'org l'ex-membro non le vede (nessun push, nessun leak).
    def cancel_pending_notifications
      Alerting::Notification
        .where(account_id: @account.id, organization_id: @organization.id, status: %i[held queued])
        .update_all(status: :skipped) # rubocop:disable Rails/SkipsModelValidations
    end

    def remove_membership
      @organization.memberships.find_by(account: @account)&.destroy!
    end
  end
end
