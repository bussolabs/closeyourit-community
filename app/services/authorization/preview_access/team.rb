# frozen_string_literal: true

module Authorization
  module PreviewAccess
    # Schema what-if per un TEAM: per ogni membro (unione dei membri attuali e pendenti) confronta i suoi
    # permessi effettivi ATTUALI con quelli risultanti applicando ruoli/scope/membri del form (rollback,
    # zero persistenza). Segnala i membri aggiunti/rimossi rispetto allo stato salvato (membership_change).
    class Team < ApplicationService
      include Diffing

      def initialize(team:, projects:, params:)
        @team = team
        @organization = team.organization
        @projects = projects
        @params = params
      end

      # Ritorna un Array di Authorization::MatrixDiff, uno per membro (ordine: attuali poi nuovi).
      def call
        current_ids = @team.team_memberships.pluck(:account_id)
        pending_ids = sanitize_ids(@params[:member_ids])
        accounts = ordered_accounts(current_ids, pending_ids)

        current = accounts.to_h { |a| [ a.id, snapshot(a, @projects) ] }
        pending = pending_snapshots(accounts)

        accounts.map do |account|
          Authorization::MatrixDiff.new(
            subject: account,
            rows: diff_rows(@projects, current[account.id], pending[account.id]),
            org_cells: diff_org_cells(current[account.id], pending[account.id]),
            membership_change: membership_change(account.id, current_ids, pending_ids)
          )
        end
      end

      private

      # Applica i Set* del team coi params pendenti, misura ogni membro, poi rollback.
      def pending_snapshots(accounts)
        result = {}
        ActiveRecord::Base.transaction do
          Teams::SetTeamRoles.call(team: @team, role_ids: @params[:role_ids])
          Teams::SetTeamScope.call(team: @team, group_ids: @params[:group_ids], project_ids: @params[:project_ids])
          Teams::SetTeamMembers.call(team: @team, account_ids: @params[:member_ids])
          result = accounts.to_h { |a| [ a.id, snapshot(a.reload, @projects) ] }
          raise ActiveRecord::Rollback
        end
        result
      end

      # Unione membri attuali + pendenti (solo account dell'org), ordine: attuali prima, nuovi dopo.
      def ordered_accounts(current_ids, pending_ids)
        ids = (current_ids + pending_ids).uniq
        by_id = @organization.accounts.where(id: ids).index_by(&:id)
        ids.filter_map { |id| by_id[id] }
      end

      def membership_change(account_id, current_ids, pending_ids)
        in_current = current_ids.include?(account_id)
        in_pending = pending_ids.include?(account_id)
        return :added   if in_pending && !in_current
        return :removed if in_current && !in_pending

        nil
      end

      def sanitize_ids(ids) = Array(ids).reject(&:blank?)
    end
  end
end
