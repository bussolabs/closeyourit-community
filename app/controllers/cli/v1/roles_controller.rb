# frozen_string_literal: true

module Cli
  module V1
    # Ruoli RBAC (Authorization::Role) dell'org del token. Tutto gated da `permissions.manage` (org-level,
    # come Member::RolesController). Le chiavi-permesso si sincronizzano via Authorization::SetRolePermissions
    # (scarta le chiavi fuori Catalog). Scoping org → id di un'altra org dà R404 (anti-BOLA).
    class RolesController < Cli::V1::BaseController
      before_action :require_permissions_manage
      before_action :set_role, only: %i[show update destroy]

      def index
        records, meta = paginate(org_roles.ordered)
        render_ok(RoleSerializer.new(records), meta: meta)
      end

      def show
        render_ok(RoleSerializer.new(@role))
      end

      def create
        role = org_roles.new(role_params)
        role.created_by = Current.account
        if role.save
          result = sync_permissions(role)
          if result&.err?
            # Escalation bloccata (R403-ACCESS-001): il ruolo è vuoto (fail-fast) → lo rimuovo e propago l'errore.
            role.destroy
            render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
          else
            render_created(RoleSerializer.new(role))
          end
        else
          render_role_invalid(role)
        end
      end

      def update
        if @role.update(role_params)
          result = sync_permissions(@role)
          if result&.err?
            render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
          else
            render_ok(RoleSerializer.new(@role))
          end
        else
          render_role_invalid(@role)
        end
      end

      def destroy
        @role.destroy
        render_no_content
      end

      private

      def org_roles
        Current.organization.roles
      end

      def set_role
        @role = org_roles.find(params[:id])
      end

      def role_params
        params.permit(:name, :color)
      end

      # Sincronizza i permessi SOLO se la chiave è stata passata (update parziale lascia i permessi invariati).
      def sync_permissions(role)
        return unless params.key?(:permission_keys)

        Authorization::SetRolePermissions.call(
          role:, permission_keys: Array(params[:permission_keys]).reject(&:blank?),
          actor: Current.account, true_actor: Current.account
        )
      end

      def render_role_invalid(role)
        render_error("R422-ROLE-001", role.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: role.errors.to_hash)
      end

      def require_permissions_manage
        require_permission!("permissions.manage")
      end
    end
  end
end
