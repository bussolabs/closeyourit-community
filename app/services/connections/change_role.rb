# frozen_string_literal: true

module Connections
  # Cambia il ruolo di una membership (member <-> admin). Vieta di declassare l'ultimo owner.
  class ChangeRole < ApplicationService
    ALLOWED_ROLES = %w[member admin].freeze

    def initialize(membership:, role:)
      @membership = membership
      @role = role.to_s
    end

    def call
      return err("R422-MEMBER-001", :invalid_role) unless ALLOWED_ROLES.include?(@role)
      return err("R422-MEMBER-002", :last_owner) if demoting_last_owner?

      @membership.update!(role: @role)
      Result.ok(@membership)
    rescue ActiveRecord::RecordInvalid => e
      # simplecov:disable difensivo — i guard (ruolo non valido / ultimo owner) intercettano prima del save;
      # resta come rete per validazioni DB impreviste.
      Result.err(AppError.new(e.message, code: "R422-MEMBER-003", details: e.record.errors.to_hash))
      # simplecov:enable
    end

    private

    def demoting_last_owner?
      return false unless @membership.owner?

      @membership.organization.memberships.owner.where.not(id: @membership.id).none?
    end

    def err(code, key)
      Result.err(AppError.new(I18n.t("member.errors.#{key}"), code: code))
    end
  end
end
