# frozen_string_literal: true

module Authorization
  module PreviewAccess
    # Schema what-if per un singolo account: confronta i permessi effettivi ATTUALI con quelli che
    # risulterebbero applicando i params del form (scope gruppi/progetti, ruoli diretti, override),
    # SENZA persistere nulla (i Set* girano dentro una transazione con Rollback → identico al salvataggio).
    class Member < ApplicationService
      include Diffing

      def initialize(organization:, account:, projects:, params:)
        @organization = organization
        @account = account
        @projects = projects
        @params = params
      end

      # Ritorna un Authorization::MatrixDiff (soggetto singolo, nessun membership_change).
      def call
        current = snapshot(@account, @projects)
        pending = pending_snapshot
        Authorization::MatrixDiff.new(
          subject: @account,
          rows: diff_rows(@projects, current, pending),
          org_cells: diff_org_cells(current, pending),
          membership_change: nil
        )
      end

      private

      # Applica i Set* coi params pendenti, misura, poi rollback: zero persistenza (audit incluso).
      def pending_snapshot
        result = nil
        ActiveRecord::Base.transaction do
          apply_pending
          result = snapshot(@account.reload, @projects)
          raise ActiveRecord::Rollback
        end
        result
      end

      def apply_pending
        Connections::SetMemberAccess.call(
          organization: @organization, account: @account,
          group_ids: @params[:group_ids], project_ids: @params[:project_ids]
        )
        Authorization::SetAccountRoles.call(
          organization: @organization, account: @account, role_ids: @params[:role_ids]
        )
        allow, deny = split_overrides(@params[:overrides])
        Authorization::SetAccountPermissions.call(
          organization: @organization, account: @account, allow_keys: allow, deny_keys: deny
        )
      end

      # { key => "inherit|allow|deny" } → [allow_keys, deny_keys] (mirror del controller).
      def split_overrides(overrides)
        allow = []
        deny = []
        overrides&.each_pair do |key, value|
          allow << key if value == "allow"
          deny << key if value == "deny"
        end
        [ allow, deny ]
      end
    end
  end
end
