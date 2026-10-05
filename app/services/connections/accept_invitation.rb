# frozen_string_literal: true

module Connections
  # Accetta un invito: crea l'Account (nome + password dall'invitato) OPPURE collega l'account già
  # esistente con quell'email, lo unisce all'organizzazione col ruolo dell'invito e marca l'invito
  # accettato. Email e org vengono dall'invito (read-only).
  class AcceptInvitation < ApplicationService
    # Esito: l'account (nuovo o preesistente) + se è stato creato ora. new_account guida l'auto-login
    # nel controller: un account PREESISTENTE non va loggato coi dati dell'invito (chiunque abbia il
    # link entrerebbe come lui) → deve autenticarsi.
    Accepted = Data.define(:account, :new_account)
    def initialize(invitation:, name:, password:, password_confirmation: nil)
      @invitation = invitation
      @name = name
      @password = password
      @password_confirmation = password_confirmation
    end

    def call
      return Result.err(already_accepted_error) if @invitation.accepted?

      # Se esiste già un account con l'email invitata, si COLLEGA la membership a quello (CYRA-164)
      # invece di tentare un Account.create! che violerebbe l'unicità email e bloccherebbe l'ingresso.
      existing = Accounts::Account.find_by(email: @invitation.email)
      account = existing

      ActiveRecord::Base.transaction do
        account ||= Accounts::Account.create!(
          name: @name, email: @invitation.email,
          password: @password, password_confirmation: @password_confirmation
        )
        # Idempotente: se è già membro (invito ridondante) il ruolo esistente NON viene sovrascritto.
        Connections::Membership.find_or_create_by!(account: account, organization: @invitation.organization) do |membership|
          membership.role = @invitation.role
        end
        @invitation.update!(accepted_at: Time.current)
      end

      Result.ok(Accepted.new(account: account, new_account: existing.nil?))
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-INVITE-001", details: e.record.errors.to_hash))
    end

    private

    def already_accepted_error
      AppError.new("Invito già accettato", code: "R422-INVITE-002")
    end
  end
end
