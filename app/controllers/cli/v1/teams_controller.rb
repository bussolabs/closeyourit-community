# frozen_string_literal: true

module Cli
  module V1
    # Team (Teams::Team = persone con scope) dell'org del token. Gated da `permissions.manage` (org-level,
    # come Member::TeamsController). create/update applicano ruoli + scope (gruppi/progetti) + membri via i
    # setter idempotenti, che scartano gli id fuori org (tenant-safe). Scoping org → R404 (anti-BOLA).
    class TeamsController < Cli::V1::BaseController
      before_action :require_permissions_manage
      before_action :set_team, only: %i[show update destroy]

      def index
        records, meta = paginate(org_teams.ordered)
        render_ok(TeamSerializer.new(records), meta: meta)
      end

      def show
        render_ok(TeamSerializer.new(@team))
      end

      def create
        team = org_teams.new(team_params)
        team.created_by = Current.account
        if team.save
          result = sync_team(team)
          if result&.err?
            # Escalation bloccata (R403-ACCESS-001): niente ruoli/scope/membri applicati (short-circuit) → rimuovo il team.
            team.destroy
            render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
          else
            render_created(TeamSerializer.new(team.reload))
          end
        else
          render_team_invalid(team)
        end
      end

      def update
        if @team.update(team_params)
          result = sync_team(@team)
          if result&.err?
            render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
          else
            render_ok(TeamSerializer.new(@team.reload))
          end
        else
          render_team_invalid(@team)
        end
      end

      def destroy
        @team.destroy
        render_no_content
      end

      private

      def org_teams
        Current.organization.teams
      end

      def set_team
        @team = org_teams.find(params[:id])
      end

      def team_params
        params.permit(:name, :color)
      end

      # Applica ruoli/scope/membri SOLO per le chiavi passate: un update parziale non azzera ciò che non tocchi.
      # Short-circuit al PRIMO guard che rifiuta (R403-ACCESS-001): ruoli (chiavi possedute) PRIMA, poi
      # scope (visibilità dell'attore, CYRA-237), infine i membri. Ogni Result va PROPAGATO col suo status,
      # non ingoiato (era un falso 2xx). Ritorna l'ultimo Result applicato (nil se non c'era nulla da fare).
      def sync_team(team)
        actor = Current.account
        result = nil
        if params.key?(:role_ids)
          result = Teams::SetTeamRoles.call(team:, role_ids: params[:role_ids], actor:, true_actor: actor)
          return result if result.err?
        end
        scope = {}
        scope[:group_ids] = params[:group_ids] if params.key?(:group_ids)
        scope[:project_ids] = params[:project_ids] if params.key?(:project_ids)
        if scope.any?
          result = Teams::SetTeamScope.call(team:, **scope, actor:, true_actor: actor)
          return result if result.err?
        end
        if params.key?(:member_ids)
          result = Teams::SetTeamMembers.call(team:, account_ids: params[:member_ids], actor:, true_actor: actor)
          return result if result.err?
        end
        result
      end

      def render_team_invalid(team)
        render_error("R422-TEAM-001", team.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: team.errors.to_hash)
      end

      def require_permissions_manage
        require_permission!("permissions.manage")
      end
    end
  end
end
