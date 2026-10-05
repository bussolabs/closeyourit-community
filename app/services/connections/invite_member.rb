# frozen_string_literal: true

module Connections
  # Crea un invito a un'organizzazione e invia l'email di accept-flow.
  # Ruoli ammessi: member/admin (owner è trasferimento, fuori scope). Result pattern.
  class InviteMember < ApplicationService
    ALLOWED_ROLES = %w[member admin customer].freeze

    def initialize(organization:, email:, role:, invited_by:)
      @organization = organization
      @email = email.to_s.strip.downcase
      @role = role.to_s
      @invited_by = invited_by
    end

    def call
      return err("R422-INVITE-003", :invalid_role) unless ALLOWED_ROLES.include?(@role)
      return err("R422-INVITE-004", :already_member) if already_member?
      return err("R422-INVITE-005", :pending_invitation) if pending_invitation?

      invitation = @organization.invitations.create!(email: @email, role: @role, invited_by: @invited_by)
      Connections::InvitationsMailer.invite(invitation).deliver_later
      Result.ok(invitation)
    rescue ActiveRecord::RecordInvalid => e
      Result.err(AppError.new(e.message, code: "R422-INVITE-005", details: e.record.errors.to_hash))
    end

    private

    def already_member?
      @organization.accounts.exists?(email: @email)
    end

    # Un invito ANCORA IN ATTESA per la stessa email: l'unicità (validazione + indice parziale) lo
    # rifiuterebbe comunque, ma con il messaggio grezzo di RecordInvalid ("Email è già stato preso"),
    # che è esattamente quello che per mesi ha fatto credere a un problema di account. Stesso codice
    # d'errore del RecordInvalid, così i client non vedono un contratto nuovo.
    def pending_invitation?
      @organization.invitations.pending.exists?(email: @email)
    end

    def err(code, key)
      Result.err(AppError.new(I18n.t("member.errors.#{key}"), code: code))
    end
  end
end
